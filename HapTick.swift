// HapTick: menu bar app that buzzes the MacBook trackpad when a notification arrives.
//
// Haptics use the private MultitouchSupport framework; notification detection reads
// Notification Center's accessibility tree, so the app needs Accessibility permission.
// Notification text is only compared in memory to spot new banners; it is never stored.

import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Settings

enum Pattern: String, CaseIterable, Identifiable {
    case tap, double, notify, alert
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var count: Int { [.tap: 1, .double: 2, .notify: 3, .alert: 6][self]! }
    var intervalMs: Int { [.tap: 0, .double: 150, .notify: 120, .alert: 80][self]! }
}

enum Strength: Int, CaseIterable, Identifiable {
    case light = 2, medium = 4, strong = 6
    var id: Int { rawValue }
    var title: String { String(describing: self).capitalized }
}

enum Key {
    static let enabled = "enabled" // old on/off switch, migrated to Pause
    static let pattern = "pattern"
    static let strength = "strength"
    static let pausedUntil = "pausedUntil"
    static let buzzCalls = "buzzCalls"
    static let knownApps = "knownApps"
    static let mutedApps = "mutedApps"
    static let buzzNewApps = "buzzNewApps"
    static let debugLog = "debugLog"
    static let messageCooldown = "messageCooldown"
}

let defaults: UserDefaults = {
    let d = UserDefaults.standard
    d.register(defaults: [
        Key.pattern: Pattern.notify.rawValue,
        Key.strength: Strength.strong.rawValue,
        Key.pausedUntil: 0.0,
        Key.buzzCalls: true,
        Key.knownApps: ["WhatsApp", "Microsoft Outlook", "Microsoft Teams", "Calendar", "Reminders",
                        "Messages", "Mail", "FaceTime", "Phone"],
        Key.mutedApps: [String](),
        Key.buzzNewApps: true,
        Key.debugLog: false,
        Key.messageCooldown: 30,
    ])
    return d
}()

// MARK: - Pause

// Pausing silences notification buzzes (not Test Buzz or the timer).
// Stored as seconds since 1970; 0 means not paused, -1 means until resumed.
enum Pause {
    static let untilResumed: Double = -1

    /// When the pause ends, `.distantFuture` if it lasts until resumed, or nil if not paused.
    static var until: Date? {
        let value = defaults.double(forKey: Key.pausedUntil)
        if value == untilResumed { return .distantFuture }
        return value > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: value) : nil
    }

    static func start(minutes: Int?) {
        let value = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)).timeIntervalSince1970 } ?? untilResumed
        defaults.set(value, forKey: Key.pausedUntil)
    }

    static func resume() { defaults.set(0.0, forKey: Key.pausedUntil) }
}

// MARK: - Haptics

final class Haptics {
    static let shared = Haptics()

    private typealias CreateFn = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias OpenFn = @convention(c) (CFTypeRef) -> IOReturn
    private typealias ActuateFn = @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> IOReturn
    private typealias CloseFn = @convention(c) (CFTypeRef) -> IOReturn

    private var create: CreateFn?, open: OpenFn?, actuate: ActuateFn?, close: CloseFn?
    private let queue = DispatchQueue(label: "haptics")

    private init() {
        guard let mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
        else { return }
        func sym<T>(_ name: String) -> T? { dlsym(mt, name).map { unsafeBitCast($0, to: T.self) } }
        create = sym("MTActuatorCreateFromDeviceID")
        open = sym("MTActuatorOpen")
        actuate = sym("MTActuatorActuate")
        close = sym("MTActuatorClose")
    }

    // Checks each step of the haptics path; used by --self-test.
    func selfTest() -> [(String, Bool)] {
        var results = [("MultitouchSupport framework loaded", create != nil && open != nil && actuate != nil && close != nil)]
        let actuator = openActuator()
        results.append(("Trackpad actuator opened", actuator != nil))
        if let actuator, let actuate, let close {
            results.append(("Haptic pulse sent", actuate(actuator, 6, 0, 0, 0) == kIOReturnSuccess))
            usleep(50_000)
            _ = close(actuator)
        }
        return results
    }

    func play(_ pattern: Pattern, strength: Strength) {
        queue.async { self.run(pattern, Int32(strength.rawValue)) }
    }

    func playSaved() {
        play(Pattern(rawValue: defaults.string(forKey: Key.pattern) ?? "") ?? .notify,
             strength: Strength(rawValue: defaults.integer(forKey: Key.strength)) ?? .strong)
    }

    // Opens the actuator per play so it survives sleep/wake and trackpad reconnects.
    private func run(_ pattern: Pattern, _ waveform: Int32) {
        guard let actuator = openActuator(), let actuate, let close else { return }
        for i in 0..<pattern.count {
            if i > 0 { usleep(useconds_t(pattern.intervalMs * 1000)) }
            _ = actuate(actuator, waveform, 0, 0, 0)
        }
        usleep(50_000)
        _ = close(actuator)
    }

    private func openActuator() -> CFTypeRef? {
        guard let create, let open else { return nil }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }
        while case let dev = IOIteratorNext(iter), dev != 0 {
            defer { IOObjectRelease(dev) }
            guard let id = IORegistryEntryCreateCFProperty(dev, "Multitouch ID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber,
                let actuator = create(id.uint64Value)?.takeRetainedValue()
            else { continue }
            if open(actuator) == kIOReturnSuccess { return actuator }
        }
        return nil
    }
}

// MARK: - App filter

// Apps are identified by the name Notification Center puts first in a banner's label.
// Apps seen for the first time are added to the list, muted unless "Buzz for New Apps" is on.
enum AppFilter {
    // Some apps (e.g. WhatsApp) prefix their name with invisible direction marks.
    static func clean(_ name: String) -> String {
        let n = String(String.UnicodeScalarView(name.unicodeScalars.filter { $0.properties.generalCategory != .format }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // FaceTime/Phone banners sometimes show an untranslated key like "FACETIME_NOTIFICATION".
        if n.hasPrefix("FACETIME_") { return "FaceTime" }
        return n
    }

    // Tidy up names saved before clean() existed, merging duplicates.
    static func migrate() {
        for key in [Key.knownApps, Key.mutedApps] {
            var seen = Set<String>()
            let list = (defaults.stringArray(forKey: key) ?? []).map(clean).filter { seen.insert($0).inserted }
            defaults.set(list, forKey: key)
        }
    }

    static func allows(_ app: String) -> Bool {
        if app.isEmpty { return true }
        var known = defaults.stringArray(forKey: Key.knownApps) ?? []
        var muted = defaults.stringArray(forKey: Key.mutedApps) ?? []
        if !known.contains(app) {
            known.append(app)
            defaults.set(known, forKey: Key.knownApps)
            if !defaults.bool(forKey: Key.buzzNewApps) {
                muted.append(app)
                defaults.set(muted, forKey: Key.mutedApps)
            }
        }
        return !muted.contains(app)
    }
}

// MARK: - Source tags

// Labels where an app's notifications come from. Anything that isn't a Mac app,
// a Chrome web app or a known macOS system source was forwarded from the iPhone.
enum SourceTag {
    // System notifications with no app on disk (AirDrop is prefix-matched).
    private static let system: Set<String> = [
        "Bluetooth", "Wi-Fi", "Software Update", "Time Machine", "Screen Time", "Focus", "Low Battery", "Siri",
    ]
    private static var macNames = Set<String>()
    private static var chromeAppNames = Set<String>()
    private static var builtAt = Date.distantPast

    static func tag(for app: String) -> String? {
        if chromeAppNames.contains(app) { return "Chrome" }
        if macNames.contains(app) || system.contains(app) || app.hasPrefix("AirDrop") { return nil }
        return "iPhone"
    }

    /// Rescans installed apps, at most once a minute.
    static func refresh() {
        guard Date().timeIntervalSince(builtAt) > 60 else { return }
        builtAt = Date()
        let fm = FileManager.default
        var names = Set<String>()
        // Apps registered for notifications, including system bundles like Calendar's.
        let registered = CFPreferencesCopyAppValue("apps" as CFString, "com.apple.ncprefs" as CFString) as? [[String: Any]] ?? []
        for entry in registered {
            if let path = entry["path"] as? String, !path.isEmpty, let n = bundleName(path) { names.insert(n) }
        }
        let home = NSHomeDirectory()
        for dir in ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", home + "/Applications"] {
            names.formUnion(appNames(in: dir))
        }
        macNames = names
        chromeAppNames = appNames(in: home + "/Applications/Chrome Apps.localized")
    }

    private static func appNames(in dir: String) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return Set(files.filter { $0.hasSuffix(".app") }.flatMap { f -> [String] in
            let path = dir + "/" + f
            return [bundleName(path), String(f.dropLast(4))].compactMap { $0 }
        })
    }

    private static func bundleName(_ path: String) -> String? {
        guard let b = Bundle(path: path) else { return nil }
        let keys = ["CFBundleDisplayName", "CFBundleName"]
        for dict in [b.localizedInfoDictionary, b.infoDictionary] {
            for k in keys { if let n = dict?[k] as? String, !n.isEmpty { return n } }
        }
        return nil
    }
}

// MARK: - Notification watcher

final class Watcher {
    private let ringRepeat: TimeInterval = 2
    private let ringMax: TimeInterval = 45

    private var seen = Set<String>()
    private var ringStart: [String: Date] = [:]
    private var lastRing = Date.distantPast
    private var lastMessageBuzz: [String: Date] = [:]

    func start() {
        let t = Thread { [self] in
            while true {
                usleep(400_000)
                if AXIsProcessTrusted() { tick() } else { seen = [] }
            }
        }
        t.qualityOfService = .utility
        t.start()
    }

    private struct Banner { let key: String; let app: String; let ringing: Bool; let element: AXUIElement }

    private func tick() {
        guard let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
        else { return }
        let app = AXUIElementCreateApplication(nc.processIdentifier)
        let windows = attr(app, "AXWindows") as? [AXUIElement] ?? []
        // The full panel (opened from the clock) lists old notifications; ignore it while open.
        if windows.contains(where: { isPanel($0) }) {
            seen = []
            ringStart = [:]
            return
        }
        var current: [Banner] = []
        for w in windows { collect(w, into: &current) }

        let keys = Set(current.map(\.key))
        let fresh = current.filter { !seen.contains($0.key) && AppFilter.allows($0.app) }
        fresh.forEach(logBanner)
        seen = keys
        ringStart = ringStart.filter { keys.contains($0.key) }

        let buzzCalls = defaults.bool(forKey: Key.buzzCalls)
        for b in fresh where b.ringing && buzzCalls { ringStart[b.key] = Date() }

        guard Pause.until == nil else { return }
        let now = Date()
        // Calls always get through. Messages from an app that buzzed within the
        // cooldown are grouped into that earlier buzz, so a busy chat buzzes once.
        let calls = fresh.filter(\.ringing)
        let cooldown = TimeInterval(defaults.integer(forKey: Key.messageCooldown))
        let messages = fresh.filter { b in
            !b.ringing && now.timeIntervalSince(lastMessageBuzz[b.app] ?? .distantPast) >= cooldown
        }
        let grouped = fresh.count - calls.count - messages.count
        if grouped > 0 { writeLog("grouped \(grouped) message(s) into an earlier buzz") }
        if !calls.isEmpty && buzzCalls {
            writeLog("buzz: call")
            ring(now)
        } else if !calls.isEmpty || !messages.isEmpty {
            writeLog("buzz: message")
            Haptics.shared.playSaved()
        } else if ringStart.values.contains(where: { now.timeIntervalSince($0) < ringMax }),
                  now.timeIntervalSince(lastRing) >= ringRepeat {
            ring(now)
        }
        for b in messages { lastMessageBuzz[b.app] = now }
    }

    private func ring(_ now: Date) {
        let strength = Strength(rawValue: defaults.integer(forKey: Key.strength)) ?? .strong
        Haptics.shared.play(.alert, strength: strength)
        lastRing = now
    }

    private func collect(_ e: AXUIElement, _ depth: Int = 0, into out: inout [Banner]) {
        if depth > 8 { return }
        let sub = attr(e, "AXSubrole") as? String ?? ""
        if sub.hasPrefix("AXNotificationCenter") {
            let desc = attr(e, "AXDescription") as? String ?? ""
            let app = AppFilter.clean(desc.components(separatedBy: ", ").first ?? "")
            let ringing = hasCallButtons(e) || isCall(app: app, desc: desc)
            out.append(Banner(key: sub + "|" + desc, app: app, ringing: ringing, element: e))
            return
        }
        for c in attr(e, "AXChildren") as? [AXUIElement] ?? [] { collect(c, depth + 1, into: &out) }
    }

    // Only the full panel has the Edit Widgets button. (Stacked banners also use
    // an "AXNotificationListItems" list, so that can't be used to spot the panel.)
    private func isPanel(_ e: AXUIElement, _ depth: Int = 0) -> Bool {
        if attr(e, "AXIdentifier") as? String == "widget-editor-button" { return true }
        if depth >= 5 { return false }
        return (attr(e, "AXChildren") as? [AXUIElement] ?? []).contains { isPanel($0, depth + 1) }
    }

    // Call buttons are often hidden until hover, so also match on app and wording.
    private func isCall(app: String, desc: String) -> Bool {
        let d = desc.lowercased()
        if d.contains("missed") { return false }
        if ["Phone", "FaceTime"].contains(app) { return true }
        return ["incoming call", "incoming voice call", "incoming video call", "incoming audio call",
                "is calling", "calling you", "voice call", "video call", "audio call", "facetime audio"]
            .contains(where: d.contains)
    }

    // Debug log (opt-in): each new banner's app, call flag and shape (roles and button
    // names only, never its text), to help tune call detection.
    private func logBanner(_ b: Banner) {
        guard defaults.bool(forKey: Key.debugLog) else { return }
        func shape(_ e: AXUIElement, _ depth: Int) -> String {
            let role = attr(e, "AXRole") as? String ?? "?"
            let sub = attr(e, "AXSubrole") as? String ?? ""
            var s = role + (sub.isEmpty ? "" : "[\(sub)]")
            if role == "AXButton" { s += "(\((attr(e, "AXDescription") ?? attr(e, "AXTitle")) as? String ?? ""))" }
            let kids = depth < 4 ? (attr(e, "AXChildren") as? [AXUIElement] ?? []) : []
            return kids.isEmpty ? s : s + "{" + kids.map { shape($0, depth + 1) }.joined(separator: " ") + "}"
        }
        writeLog("app=\(b.app) call=\(b.ringing) \(shape(b.element, 0))")
    }

    private func writeLog(_ message: String) {
        guard defaults.bool(forKey: Key.debugLog) else { return }
        let line = "\(Date()) \(message)\n"
        let url = URL(fileURLWithPath: NSString(string: "~/Library/Logs/HapTick.log").expandingTildeInPath)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func hasCallButtons(_ e: AXUIElement, _ depth: Int = 0) -> Bool {
        if depth > 4 { return false }
        for c in attr(e, "AXChildren") as? [AXUIElement] ?? [] {
            if attr(c, "AXRole") as? String == "AXButton" {
                let t = ((attr(c, "AXDescription") ?? attr(c, "AXTitle")) as? String ?? "").lowercased()
                if ["accept", "answer", "decline"].contains(where: t.contains) { return true }
            }
            if hasCallButtons(c, depth + 1) { return true }
        }
        return false
    }

    private func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(e, a as CFString, &v)
        return v
    }
}

// MARK: - Self-test

// `HapTick --self-test` prints a diagnostic report and exits. Useful for bug reports.
func runSelfTest() -> Never {
    var translated: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
    #if arch(arm64)
    let arch = "arm64 (Apple Silicon)"
    #else
    let arch = translated == 1 ? "x86_64 (Intel, running under Rosetta)" : "x86_64 (Intel)"
    #endif
    print("HapTick self-test")
    print("  Architecture: \(arch)")
    print("  macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

    var results = Haptics.shared.selfTest()
    results.append(("Accessibility permission granted", AXIsProcessTrusted()))
    let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
    results.append(("Notification Center found", nc != nil))
    if let nc {
        var windows: AnyObject?
        let err = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(nc.processIdentifier), "AXWindows" as CFString, &windows)
        results.append(("Notification Center readable", err == .success))
    }
    for (name, ok) in results { print("  [\(ok ? "PASS" : "FAIL")] \(name)") }
    exit(results.allSatisfy(\.1) ? 0 : 1)
}

// MARK: - UI

final class AppState: ObservableObject {
    static let timerMinutes = [10, 15, 20, 30, 45, 60]
    private let doneBuzzMax: TimeInterval = 60

    @Published var trusted = AXIsProcessTrusted()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var timerEnd: Date?
    @Published private(set) var timerDoneAt: Date?
    @Published private(set) var now = Date()
    @Published private(set) var knownApps: [String] = []
    @Published private(set) var mutedApps: [String] = []
    @Published private(set) var pausedUntil = Pause.until
    private var lastDoneBuzz = Date.distantPast

    init() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common) // keep ticking while the menu is open
    }

    private func tick() {
        now = Date()
        let t = AXIsProcessTrusted()
        if trusted != t { trusted = t }
        loadApps()
        let paused = Pause.until // timed pauses end on their own
        if paused != pausedUntil { pausedUntil = paused }

        if let end = timerEnd, now >= end {
            timerEnd = nil
            timerDoneAt = now
            lastDoneBuzz = .distantPast
        }
        // Buzz until the user touches the Mac, or give up after a minute.
        if let done = timerDoneAt {
            let anyInput = CGEventType(rawValue: ~0)!
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
            let elapsed = now.timeIntervalSince(done)
            if elapsed > doneBuzzMax || idle < elapsed - 1 {
                timerDoneAt = nil
            } else if now.timeIntervalSince(lastDoneBuzz) >= 2 {
                Haptics.shared.play(.alert, strength: .strong)
                lastDoneBuzz = now
            }
        }
    }

    // The watcher thread can add apps, so pick up changes from defaults each tick.
    private func loadApps() {
        let known = (defaults.stringArray(forKey: Key.knownApps) ?? []).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let muted = defaults.stringArray(forKey: Key.mutedApps) ?? []
        if known != knownApps {
            SourceTag.refresh()
            knownApps = known
        }
        if muted != mutedApps { mutedApps = muted }
    }

    func pause(minutes: Int?) {
        Pause.start(minutes: minutes)
        pausedUntil = Pause.until
    }

    func resume() {
        Pause.resume()
        pausedUntil = nil
    }

    var pauseText: String? {
        guard let until = pausedUntil else { return nil }
        if until == .distantFuture { return "Paused until you resume" }
        return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
    }

    func setMuted(_ app: String, _ muted: Bool) {
        var list = (defaults.stringArray(forKey: Key.mutedApps) ?? []).filter { $0 != app }
        if muted { list.append(app) }
        defaults.set(list, forKey: Key.mutedApps)
        loadApps()
    }

    func startTimer(minutes: Int) {
        timerDoneAt = nil
        timerEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
        now = Date()
    }

    func cancelTimer() {
        timerEnd = nil
        timerDoneAt = nil
    }

    var timerText: String? {
        if timerDoneAt != nil { return "Done" }
        guard let end = timerEnd else { return nil }
        let s = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func requestAccess() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("HapTick: login item change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState
    @AppStorage(Key.pattern) var pattern = Pattern.notify.rawValue
    @AppStorage(Key.strength) var strength = Strength.strong.rawValue
    @AppStorage(Key.buzzCalls) var buzzCalls = true
    @AppStorage(Key.buzzNewApps) var buzzNewApps = true
    @AppStorage(Key.debugLog) var debugLog = false
    @AppStorage(Key.messageCooldown) var messageCooldown = 30
    @AppStorage("appsExpanded") var appsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("HapTick").font(.headline)

            if !state.trusted {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Accessibility access needed to see notifications", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                    Button("Grant Access…") { state.requestAccess() }
                }
            }

            section("Pause") {
                if let text = state.pauseText {
                    HStack {
                        Label(text, systemImage: "pause.circle.fill").foregroundStyle(.orange)
                        Spacer()
                        Button("Resume") { state.resume() }
                    }
                } else {
                    Menu("Pause buzzes for…") {
                        Button("15 minutes") { state.pause(minutes: 15) }
                        Button("30 minutes") { state.pause(minutes: 30) }
                        Button("1 hour") { state.pause(minutes: 60) }
                        Button("2 hours") { state.pause(minutes: 120) }
                        Divider()
                        Button("Until I turn them back on") { state.pause(minutes: nil) }
                    }
                    .fixedSize()
                    .help("Silences notification buzzes. Test Buzz and the timer still work.")
                }
            }

            section("Feel") {
                Picker("Pattern", selection: $pattern) {
                    ForEach(Pattern.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented)
                Picker("Strength", selection: $strength) {
                    ForEach(Strength.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Group Burst Alerts ") + Text("(choose cooldown)").foregroundColor(.secondary)
                    Picker("Group Burst Alerts", selection: $messageCooldown) {
                        Text("Off").tag(0)
                        Text("10s").tag(10)
                        Text("30s").tag(30)
                        Text("1m").tag(60)
                        Text("5m").tag(300)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .help("After a buzz, more messages from the same app stay silent for this long. Calls always buzz.")
                Button("Test Buzz") { Haptics.shared.playSaved() }
            }

            section("Timer") {
                if state.timerDoneAt != nil {
                    HStack {
                        Text("Time's up!").font(.title3.bold())
                        Spacer()
                        Button("Stop Buzzing") { state.cancelTimer() }
                    }
                } else if let text = state.timerText {
                    HStack {
                        Text(text).font(.title2.monospacedDigit().bold())
                        Spacer()
                        Button("Cancel") { state.cancelTimer() }
                    }
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 6) {
                        ForEach(AppState.timerMinutes, id: \.self) { m in
                            Button("\(m) min") { state.startTimer(minutes: m) }
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }

            section("Apps") {
                Button { appsExpanded.toggle() } label: {
                    HStack {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(appsExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                        Text(appsSummary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if appsExpanded {
                    let rows = (state.knownApps.count + 1) / 2
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                            GridItem(.flexible(), alignment: .leading)],
                                  alignment: .leading, spacing: 4) {
                            ForEach(state.knownApps, id: \.self) { app in
                                Toggle(isOn: Binding(get: { !state.mutedApps.contains(app) },
                                                     set: { state.setMuted(app, !$0) })) {
                                    tagged(app).lineLimit(1).truncationMode(.tail)
                                }
                                .help(SourceTag.tag(for: app).map { "\(app) (\($0))" } ?? app)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(rows) * 22, 220))
                }
                Toggle("Buzz for new apps", isOn: $buzzNewApps)
            }

            section("Options") {
                Toggle("Keep buzzing for calls", isOn: $buzzCalls)
                Toggle("Start at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                Toggle("Debug log", isOn: $debugLog)
                    .help("Writes app names and banner layout (never message text) to ~/Library/Logs/HapTick.log")
            }

            Divider()
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .toggleStyle(.checkbox)
        .padding(16)
        .frame(width: 300)
        .fixedSize()
        .background(PanelResizer())
    }

    private func tagged(_ app: String) -> Text {
        guard let tag = SourceTag.tag(for: app) else { return Text(app) }
        return Text(app) + Text(" (\(tag))").foregroundColor(.secondary)
    }

    private var appsSummary: String {
        let total = state.knownApps.count
        let on = state.knownApps.filter { !state.mutedApps.contains($0) }.count
        return on == total ? "All \(total) apps buzz" : "\(on) of \(total) apps buzz"
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

// MenuBarExtra panels grow but never shrink on their own. This view sits behind the
// content, so it always has the content's size; when that changes, it resizes the
// panel to match, keeping the top edge under the menu bar.
private struct PanelResizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ResizingView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class ResizingView: NSView {
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            DispatchQueue.main.async { [weak self] in self?.fitWindow() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.fitWindow() }
        }

        private func fitWindow() {
            guard let window, bounds.width > 0, bounds.height > 0 else { return }
            let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: bounds.size)).size
            var frame = window.frame
            guard abs(frame.height - target.height) > 0.5 || abs(frame.width - target.width) > 0.5 else { return }
            frame.origin.y += frame.height - target.height
            frame.size = target
            window.setFrame(frame, display: true)
        }
    }
}

@main
struct HapTickApp: App {
    @StateObject private var state = AppState()
    private let watcher = Watcher()

    init() {
        if CommandLine.arguments.contains("--self-test") { runSelfTest() }
        AppFilter.migrate()
        // The on/off switch was replaced by Pause; keep anyone who had it off paused.
        if defaults.object(forKey: Key.enabled) as? Bool == false { Pause.start(minutes: nil) }
        defaults.removeObject(forKey: Key.enabled)
        watcher.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            let icon = Image(systemName: state.pausedUntil != nil ? "pause.circle" : "hand.tap.fill")
            if let text = state.timerText {
                Text("\(icon) \(text)").monospacedDigit()
            } else {
                icon
            }
        }
        .menuBarExtraStyle(.window)
    }
}

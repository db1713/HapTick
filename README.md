# HapTick

Feel your notifications. HapTick is a tiny macOS menu bar app that buzzes your MacBook's
Force Touch trackpad (the Taptic Engine) when a notification arrives — WhatsApp, Outlook,
Teams, Calendar, anything that shows a banner — so you notice it even with the sound off.

## Features

- **Haptic notifications** — a trackpad buzz for every notification banner
- **Per-app control** — choose which apps buzz; new apps are added automatically
- **Calls keep buzzing** — incoming calls buzz every 2 seconds until answered or dismissed
- **Timer** — 10 / 15 / 20 / 30 / 45 / 60 min, with a countdown in the menu bar and a buzz when it's done
- **Patterns and strength** — Tap, Double, Notify or Alert; Light, Medium or Strong
- **Stays out of the way** — quiet when the screen is locked or you've stepped away; ignores the
  Notification Center panel when you open it yourself

## Requirements

- A Mac with a Force Touch trackpad (MacBooks from 2015 on, or a Magic Trackpad 2+)
- macOS 13 Ventura or later
- Apple Silicon or Intel (tested on Apple Silicon; the Intel build is tested under Rosetta only —
  reports from real Intel Macs welcome)

## Install

1. Download `HapTick.zip` from the [latest release](https://github.com/db1713/HapTick/releases/latest) and unzip it.
2. Move `HapTick.app` to your Applications folder and open it.
3. macOS will say it can't verify the app, because it isn't notarized by Apple. Open
   **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
4. Click the 👆 icon in the menu bar → **Grant Access…**, and turn on HapTick under
   **Accessibility**. This is how it sees notifications arrive (see Privacy below).
5. Click **Test Buzz**.

## Privacy

HapTick needs Accessibility permission because macOS has no public way for an app to find out
that another app showed a notification. It reads the Notification Center's on-screen banners to
spot new ones and to tell which app sent them.

- Notification text is compared in memory only, to tell new banners from old ones. It is never
  saved, logged or sent anywhere.
- HapTick makes no network connections.
- It stores your settings and the list of app names it has seen.
- **Debug log** (off by default) writes the time, app name and banner layout — never the
  message — to `~/Library/Logs/HapTick.log`.

## Troubleshooting

Run the self-test and include the output in any bug report:

```sh
/Applications/HapTick.app/Contents/MacOS/HapTick --self-test
```

- **No buzz at all** — try **Test Buzz**. If that fails, your trackpad may not have a Taptic Engine.
- **Test Buzz works but notifications don't** — check the Accessibility permission. If it's on,
  remove HapTick from the list and add it again.
- **An app shows up twice in the list** — please open an issue with the app's name.

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/db1713/HapTick.git
cd HapTick
./build.sh --install   # universal build, copies to ~/Applications and launches
```

`./build.sh --zip` also creates `build/HapTick.zip`. Builds are ad-hoc signed unless a keychain
code-signing identity named `HapTick Local Signing` (or `$SIGN_IDENTITY`) exists. A stable
identity keeps the Accessibility permission across rebuilds.

## How it works

- **Haptics:** HapTick uses Apple's private `MultitouchSupport` framework to fire the trackpad
  actuator directly. The public `NSHapticFeedbackManager` API only works while a finger is
  on the trackpad.
- **Notifications:** It checks Notification Center's accessibility tree a couple of times a second
  for new banner elements.

Both rely on undocumented macOS behaviour, so a future macOS update could break them. This is
also why HapTick can't be on the Mac App Store.

## License

[MIT](LICENSE)

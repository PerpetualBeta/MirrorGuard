# MirrorGuard

A tiny macOS utility that stops accidental display mirroring. It silently swallows the ⌘F1 shortcut — the easy-to-fumble combo that toggles screen mirroring — so a stray keypress can't disrupt your setup. Everything else, including normal brightness control, is left completely untouched.

## Requirements

- macOS 14 (Sonoma) or later

## Installation

Two formats on every release — both signed and notarised, pick whichever suits:

- **[Installer (`.pkg`)](https://github.com/PerpetualBeta/MirrorGuard/releases/latest/download/MirrorGuard.pkg)** — recommended for first-time installs. Double-click to run; macOS Installer places the app in `/Applications` without quarantine or App Translocation.
- **[Download (`.zip`)](https://github.com/PerpetualBeta/MirrorGuard/releases/latest)** — unzip and drag `MirrorGuard.app` to your Applications folder.

After installation:

1. Launch MirrorGuard — a display icon appears in your menu bar
2. Grant Accessibility permission when prompted

## How It Works

On a Mac, **⌘F1** toggles display mirroring. It sits right next to combinations you reach for constantly, so it's easy to trigger by accident — and an unexpected mirror flip is disruptive, especially mid-presentation or mid-task.

MirrorGuard installs a global event tap at the HID level — *before* macOS acts on the shortcut — and discards the ⌘F1 keystroke. The mirroring toggle simply never fires.

| You press | What happens |
|-----------|--------------|
| ⌘F1 | Nothing (consumed silently — no mirroring) |
| F1 alone | Normal brightness-down, untouched |
| Any other key | Untouched |

The Command requirement is deliberate: MirrorGuard only intercepts F1 **when ⌘ is held**, so ordinary brightness control keeps working exactly as before. It matches both key-code forms of F1 (brightness-down in media-key mode, or the plain function key in standard-function-key mode), so it works regardless of your *"Use F1, F2 as standard function keys"* setting.

## Menu Bar Icon

The display icon in the menu bar reflects the engine state:

- **Plain displays**: Inactive — ⌘F1 will mirror
- **Slashed displays**: Guarding — ⌘F1 is blocked

Click the icon to access:

- **Block ⌘F1 Mirroring** — toggle the guard on/off
- **Status** — current guarding state
- **Check for Updates…** — Sparkle-driven update check
- **Settings** — toggle and permissions
- **About** — version info

## Settings

### Display Mirroring

- **Block ⌘F1 mirroring shortcut** — turn the guard on or off

### General

- **Accessibility** — permission status and grant button
- **Show icon in menu bar** — hide the status icon while MirrorGuard keeps running in the background. Your choice persists across launches, including login auto-start. *Shown only on macOS 14–15 — on macOS 26 (Tahoe) and later, use System Settings → Menu Bar, which provides this natively.*
- **Menu bar icon pill** — optional grey background for stronger contrast on busy or wallpaper-tinted menu bars (off by default)
- **Launch at Login** — start automatically when you log in

If you've hidden the status icon and want it back, simply re-open MirrorGuard from your Applications folder — it reappears immediately.

Auto-updates are handled by Sparkle. Use the **Check for Updates…** entry in the menu to check on demand.

## Permissions

### Accessibility (required)

Needed to intercept the keyboard shortcut before macOS acts on it.

- Prompted automatically on first launch
- Grant in: **System Settings → Privacy & Security → Accessibility**
- Without this, the guard cannot function

## Building from Source

MirrorGuard uses Swift Package Manager. No Xcode project is required.

```bash
cd ~/Desktop/"Jorvik Software"/MirrorGuard
gmake build
open .build/MirrorGuard.app
```

Requires GNU Make 4.x — `brew install make` installs it as `gmake`. The target is defined in the shared `release.mk` from `jorvik-release/`.

## How It Works (Technical)

MirrorGuard creates a `CGEventTap` at `kCGHIDEventTap` with `headInsertEventTap`, so it sees keyboard events before WindowServer's hotkey dispatch. It discards the mirroring combo (Command held) regardless of which form the F1/brightness-down key arrives in, returning `nil`. Every other event — including bare brightness with no modifier — passes through unchanged. The tap auto-re-enables if macOS disables it on timeout or user input.

The F1/brightness-down key is delivered in **two different forms** depending on the keyboard, and the callback handles both:

- **Regular key event** (`keyDown`/`keyUp`) with key code **122** (plain F1, standard-function-key mode) or **145** (brightness-down) — this is what external keyboards send.
- **System-defined HID event** (`NX_SYSDEFINED`, CGEvent type `14`, `NSEvent` subtype `8`) carrying NX key code **3** (`NX_KEYTYPE_BRIGHTNESS_DOWN`) — this is what the **built-in Apple keyboard** sends; it is not a key code at all, so the event mask must include `(1 << 14)` and the callback must decode the `NSEvent` payload.

Matching only the key-code form blocks the shortcut on external keyboards but silently misses it on the built-in keyboard — both forms are required.

There is no `hidutil` remapping and no persistent system change — the guard exists only while the app is running, and removing the app removes it entirely.

There is no `hidutil` remapping and no persistent system change — the guard exists only while the app is running, and removing the app removes it entirely.

## Troubleshooting

### ⌘F1 still toggles mirroring

Make sure MirrorGuard has **Accessibility** permission in System Settings → Privacy & Security → Accessibility, and that the menu shows **Block ⌘F1 Mirroring** ticked. You may need to remove and re-add the permission if you've rebuilt the app from source.

### Brightness control stopped working

MirrorGuard only intercepts F1 when ⌘ is held, so bare brightness keys should be unaffected. If they aren't, toggle the guard off and on from the menu, or restart the app.

---

MirrorGuard is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).

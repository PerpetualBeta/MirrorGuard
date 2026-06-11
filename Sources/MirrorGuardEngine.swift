import AppKit
import ApplicationServices

// MARK: - Module-level state for the C-compatible CGEvent tap callback
//
// The tap callback is a bare C function pointer, so the state it touches
// can't live on an instance — it sits at module scope, mirroring the
// pattern proven in HyperCaps.

private var _mgEventTap: CFMachPort?

/// ⌘F1 toggles display mirroring, but which key code F1 emits depends on the
/// keyboard's F-key mode:
///   • Media mode (Apple default): F1 is the brightness-down key → code 145.
///   • Standard-function-key mode: F1 is the plain function key → code 122.
/// We match both, so the guard works regardless of that System Settings
/// toggle. Verified empirically: with media keys on, ⌘F1 arrives as a normal
/// keyDown with code 145 and the Command flag set.
private let _f1KeyCode: Int64 = 122             // kVK_F1 (standard-function-key mode)
private let _brightnessDownKeyCode: Int64 = 145 // F1/brightness-down on external keyboards (regular key event)
private let _nxBrightnessDownKey: Int64 = 3     // NX_KEYTYPE_BRIGHTNESS_DOWN — built-in keyboard, delivered as a system-defined event

private func mirrorGuardTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // macOS disables a tap that times out or is interrupted by user input;
    // re-enable it and pass the triggering event through untouched.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = _mgEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    // ⌘ is required in every case below. Bare F1 / brightness (no modifier)
    // always passes straight through, so normal brightness control is never
    // affected — we only ever swallow the mirroring combo.
    let hasCommand = event.flags.contains(.maskCommand)

    // Form 1 — regular key event. External keyboards (and any keyboard in
    // standard-function-key mode) deliver F1 as a key code: 122 (plain F1)
    // or 145 (brightness-down).
    if hasCommand, type == .keyDown || type == .keyUp {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == _f1KeyCode || keyCode == _brightnessDownKeyCode {
            return nil
        }
    }

    // Form 2 — system-defined HID event. The built-in Apple keyboard delivers
    // its F1/brightness-down key as an NX_SYSDEFINED event (raw type 14,
    // subtype 8) carrying NX key code 3, not a key code. ⌘ + that is the
    // mirroring combo on the built-in keyboard, so swallow it too.
    if hasCommand, type.rawValue == 14,
       let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
        let nxKey = (ns.data1 & 0xFFFF0000) >> 16
        if nxKey == _nxBrightnessDownKey {
            return nil
        }
    }

    // Everything else passes through unchanged.
    return Unmanaged.passRetained(event)
}

// MARK: - MirrorGuardEngine

@MainActor
@Observable
final class MirrorGuardEngine {
    var isActive: Bool = false
    var permissionGranted: Bool = false

    private var eventTap: CFMachPort?
    private var permissionTimer: Timer?

    // MARK: - Public API

    func start() async {
        guard !isActive else { return }
        if tryCreateEventTap() {
            isActive = true
        }
    }

    func stop() async {
        isActive = false
        // Disable synchronously first so input is released immediately.
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        _mgEventTap = nil
    }

    /// Prompts for Accessibility access (required for an active event tap),
    /// waits until it's granted, then starts trapping. Mirrors HyperCaps so
    /// behaviour is consistent across the suite.
    func requestPermissionAndStart() async {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        permissionGranted = trusted

        if !trusted {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                    if AXIsProcessTrusted() {
                        Task { @MainActor in self?.permissionGranted = true }
                        timer.invalidate()
                        continuation.resume()
                    }
                }
            }
        }

        await start()
    }

    // MARK: - CGEvent tap

    private func tryCreateEventTap() -> Bool {
        if eventTap != nil { return true }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | (1 << 14)   // NX_SYSDEFINED — built-in keyboard's brightness/F1 key arrives here, not as a key code

        // HID-level tap: sits *before* WindowServer's hotkey dispatch, so we
        // can swallow ⌘F1 before macOS acts on it as the mirroring hotkey.
        // A session-level tap can be too late for system hotkeys.
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mirrorGuardTapCallback,
            userInfo: nil
        ) else {
            NSLog("[MirrorGuard] event tap creation failed — Accessibility not granted?")
            return false
        }

        eventTap = tap
        _mgEventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
}

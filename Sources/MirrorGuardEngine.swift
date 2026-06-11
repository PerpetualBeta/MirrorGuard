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
private let _f1KeyCode: Int64 = 122            // kVK_F1
private let _brightnessDownKeyCode: Int64 = 145 // F1 in media mode

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

    if type == .keyDown || type == .keyUp {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // Swallow ⌘ + F1 (either key-code form) so it can't toggle mirroring.
        // The Command requirement is deliberate: bare F1 / brightness-down
        // (no modifier) passes straight through, so normal brightness control
        // keeps working.
        if (keyCode == _brightnessDownKeyCode || keyCode == _f1KeyCode)
            && event.flags.contains(.maskCommand) {
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

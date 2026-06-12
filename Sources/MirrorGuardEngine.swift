import AppKit
import ApplicationServices

// MARK: - Module-level state for the C-compatible CGEvent tap callback
//
// The tap callback is a bare C function pointer, so the state it touches
// can't live on an instance — it sits at module scope, mirroring the
// pattern proven in HyperCaps.

private var _mgEventTap: CFMachPort?
// The tap's dedicated run loop, so stop() can stop it from the main actor.
private var _mgTapRunLoop: CFRunLoop?

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
    private var tapThread: Thread?
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
        // Tear down the dedicated tap thread by stopping its run loop.
        if let runLoop = _mgTapRunLoop {
            CFRunLoopStop(runLoop)
        }
        _mgTapRunLoop = nil
        tapThread = nil
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

        // Tap NX_SYSDEFINED (type 14) as well: the built-in keyboard's
        // F1/brightness key arrives as a system-defined event, not a key code,
        // so it's the only way to cover the built-in keyboard. This event class
        // is what the menu-bar layout engine also rides on — tapping it on the
        // *main* run loop wedged the whole menu bar; the dedicated tap thread
        // (below) drains it promptly and keeps the menu bar healthy.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | (1 << 14)   // NX_SYSDEFINED — built-in keyboard's F1/brightness key

        // Session-level tap. A HID-level tap (.cghidEventTap) sits earlier, but
        // in this process it orphans MirrorGuard's *own* status item — with a
        // clean install, engine-off seats the icon and engine-on (HID) parks it
        // off-screen, while HyperCaps' session tap has no such trouble. Session
        // level keeps the icon; verify it's still early enough to swallow ⌘F1
        // before the system mirrors (if not, the fallback is to disable the
        // mirroring hotkey at source rather than tap for it).
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
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

        // Service the tap on a dedicated thread — never the main run loop.
        // A .cghidEventTap sits in the system-wide HID event stream; if the
        // main run loop is busy with UI work the tap can't be drained promptly,
        // which backs up that stream and freezes system UI that depends on it.
        // Concretely: with the NX_SYSDEFINED (type 14) events in our mask, a
        // main-run-loop tap wedged the *entire menu-bar layout engine* while
        // MirrorGuard ran (new status items couldn't seat, "Allow in Menu Bar"
        // toggles went inert). A private run loop keeps the tap drained
        // independently of the app's UI work.
        let thread = Thread {
            // Reference the module-level tap rather than capturing the local,
            // so the closure doesn't capture a non-Sendable CFMachPort.
            guard let tap = _mgEventTap else { return }
            let runLoop = CFRunLoopGetCurrent()
            _mgTapRunLoop = runLoop
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "cc.jorviksoftware.MirrorGuard.eventtap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        return true
    }
}

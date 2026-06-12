import AppKit
import ApplicationServices
import SwiftUI
import ServiceManagement
import Sparkle

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    let engine = MirrorGuardEngine()
    let sparkleUserDriverDelegate = MirrorGuardUserDriverDelegate()
    lazy var sparkleUpdater = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: sparkleUserDriverDelegate
    )

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        createStatusItem()
        _ = sparkleUpdater  // forces lazy init so Sparkle starts at launch

        // Start trapping ⌘F1 (prompts for Accessibility on first launch).
        Task {
            await engine.requestPermissionAndStart()
            updateIcon()
        }

        // Redraw the status icon when the display configuration changes — the
        // menu bar's effective thickness can shrink (e.g. moving from a notched
        // display to an external one) and leave a pre-rendered pill cropped.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }

        // Create or remove the status item when the user toggles its
        // visibility in Settings.
        NotificationCenter.default.addObserver(
            forName: JorvikStatusItemVisibility.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyStatusItemVisibility() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await engine.stop() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        JorvikStatusItemVisibility.handleReopen()
        return true
    }

    // MARK: - Status item

    // Fresh slot id. The previous name ("MirrorGuardStatusItem") had picked up a
    // sticky far-right menu-bar placement (behind the system clock) that macOS
    // refused to override even after wiping the app's defaults — a new name
    // gives the item a clean slot so it lands in the normal third-party zone.
    private static let statusItemAutosaveName = "MirrorGuardMenuBarItem"

    func createStatusItem() {
        guard JorvikStatusItemVisibility.isVisible else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // autosaveName persists the item's slot across launches and lets a
        // user ⌘-drag stick. No position is seeded — macOS places it like any
        // other status item.
        statusItem?.autosaveName = Self.statusItemAutosaveName
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    func applyStatusItemVisibility() {
        if JorvikStatusItemVisibility.isVisible {
            if statusItem == nil { createStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Icon

    func updateIcon() {
        // Two overlapping rectangles read as "mirrored displays"; the slash
        // variant signals the shortcut is being blocked (guard active).
        let symbolName = engine.isActive ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle"
        statusItem?.button?.image = JorvikMenuBarPill.icon(
            symbolName: symbolName,
            accessibilityDescription: "MirrorGuard"
        )
    }

    // MARK: - Dynamic menu (NSMenuDelegate)

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateIcon()

        var actions: [JorvikMenuBuilder.ActionItem] = []

        // Toggle the ⌘F1 trap
        actions.append(JorvikMenuBuilder.ActionItem(
            title: "Block \u{2318}F1 Mirroring",
            action: #selector(toggleBlocking),
            target: self,
            state: engine.isActive ? .on : .off
        ))

        // Status line (informational, non-clickable)
        let statusText = engine.isActive ? "Guarding — \u{2318}F1 is disabled" : "Inactive — \u{2318}F1 will mirror"
        let statusAttr = NSAttributedString(string: statusText, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        actions.append(JorvikMenuBuilder.ActionItem(
            title: statusText,
            action: #selector(noop),
            target: self,
            isEnabled: false,
            attributedTitle: statusAttr
        ))

        actions.append(JorvikMenuBuilder.ActionItem(title: "-", action: #selector(noop), target: self))
        actions.append(JorvikMenuBuilder.ActionItem(
            title: "Check for Updates\u{2026}",
            action: #selector(checkForUpdates(_:)),
            target: self
        ))

        let built = JorvikMenuBuilder.buildMenu(
            appName: "MirrorGuard",
            aboutAction: #selector(openAbout),
            settingsAction: #selector(openSettings),
            target: self,
            actions: actions
        )

        menu.removeAllItems()
        for item in built.items {
            built.removeItem(item)
            menu.addItem(item)
        }
    }

    // MARK: - Actions

    @objc private func toggleBlocking() {
        Task {
            if engine.isActive {
                await engine.stop()
            } else {
                await engine.requestPermissionAndStart()
            }
            updateIcon()
        }
    }

    @objc private func noop() {}

    @objc func checkForUpdates(_ sender: Any?) {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        sparkleUpdater.checkForUpdates(sender)
    }

    // MARK: - About & Settings

    @objc private func openAbout() {
        JorvikAboutView.showWindow(
            appName: "MirrorGuard",
            repoName: "MirrorGuard",
            productPage: "utilities/mirrorguard"
        )
    }

    @objc private func openSettings() {
        let delegate = self
        JorvikSettingsView.showWindow(appName: "MirrorGuard") {
            MirrorGuardSettingsContent(delegate: delegate)
        }
    }
}

/// Keeps Sparkle's update UI visible across the whole session, including
/// when the user switches to another app mid-download. See KB:
/// `conventions/sparkle-integration.md` §6 for the rationale.
final class MirrorGuardUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    private var sessionObserver: NSObjectProtocol?
    private var elevatedWindows: [(window: NSWindow, originalLevel: NSWindow.Level)] = []

    func standardUserDriverWillShowModalAlert() {
        bringForward()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        startFocusGuard()
        bringForward()
    }

    func standardUserDriverWillFinishUpdateSession() {
        stopFocusGuard()
    }

    private func bringForward() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        elevateAllWindows()
    }

    private func startFocusGuard() {
        guard sessionObserver == nil else { return }
        sessionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bringForward()
        }
    }

    private func stopFocusGuard() {
        if let obs = sessionObserver {
            NotificationCenter.default.removeObserver(obs)
            sessionObserver = nil
        }
        for entry in elevatedWindows {
            entry.window.level = entry.originalLevel
        }
        elevatedWindows.removeAll()
    }

    private func elevateAllWindows() {
        for window in NSApp.windows where window.isVisible && window.level == .normal {
            elevatedWindows.append((window, window.level))
            window.level = .floating
        }
    }
}

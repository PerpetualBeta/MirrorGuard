import SwiftUI

struct MirrorGuardSettingsContent: View {
    let delegate: AppDelegate

    var body: some View {
        Section("Display Mirroring") {
            Toggle("Block \u{2318}F1 mirroring shortcut", isOn: Binding(
                get: { delegate.engine.isActive },
                set: { newValue in
                    Task {
                        if newValue {
                            await delegate.engine.requestPermissionAndStart()
                        } else {
                            await delegate.engine.stop()
                        }
                        delegate.updateIcon()
                    }
                }
            ))

            Text("When on, pressing \u{2318}F1 does nothing instead of toggling display mirroring. All other keys are untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Permissions") {
            HStack {
                Text("Accessibility")
                Spacer()
                if AXIsProcessTrusted() {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Button("Grant Access") {
                        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
                        AXIsProcessTrustedWithOptions(opts)
                    }
                    .font(.caption)
                }
            }
            Text("MirrorGuard needs Accessibility access to intercept the keyboard shortcut before macOS acts on it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        MenuBarVisibilitySettings()

        MenuBarPillSettings { delegate.updateIcon() }
    }
}

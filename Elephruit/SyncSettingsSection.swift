import ElephruitFeaturesCore
import ElephruitPersistence
import SwiftUI

/// The sync switch, its status, and the honest sentence about what it means.
///
/// The container decision is made once, before the first fetch, so the toggle applies at
/// the next launch — and says so in words rather than pretending to be instant. The same
/// section, in the same words, exists on the iPhone; this is a promise made in two places
/// about one behavior.
struct SyncSettingsSection: View {
    @Environment(\.services) private var services

    @AppStorage(SyncSetting.enabledKey) private var syncEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $syncEnabled) {
                    Text("Sync with iCloud")
                }

                if needsRelaunch {
                    Label(
                        syncEnabled
                            ? "Takes effect the next time Elephruit opens."
                            : "Stops at the next launch. Nothing is deleted, here or in iCloud.",
                        systemImage: "arrow.counterclockwise"
                    )
                    .foregroundStyle(.secondary)
                }

                LabeledContent("Status") {
                    Text(services?.syncStatus.summary ?? SyncStatus.disabled.summary)
                }
            } footer: {
                Text(
                    """
                    Sync keeps this Mac and your iPhone looking at one library, through your \
                    own private iCloud database. Apple's CloudKit is the only thing this app \
                    talks to on the network — no account with us, no analytics, no third-party \
                    service. Off means off: the library stays on this Mac and the network is \
                    not used at all.
                    """
                )
            }
        }
        .formStyle(.grouped)
    }

    /// The toggle and the running container disagree — the launch boundary is between them.
    private var needsRelaunch: Bool {
        guard let services else { return false }
        return syncEnabled != services.stack.isSyncEnabled
    }
}

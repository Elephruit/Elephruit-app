import ElephruitFeaturesCore
import ElephruitPersistence
import SwiftUI

/// The sync switch, its status, and the honest sentence about what it means.
///
/// The container decision is made once, before the first fetch, so the toggle applies at
/// the next launch — and says so in words rather than pretending to be instant. The same
/// section exists on the iPhone, making one promise in two places; the wording diverges
/// only where the two platforms differ in what they can reach.
///
/// ### The footer no longer follows the switch
/// It used to end "Off means off: the library stays on this Mac and the network is not used at
/// all", and that sentence was false before it was written. `MapPlaceSearchField` had already
/// shipped, and it runs an `MKLocalSearch` the moment somebody types a venue into a record —
/// with sync off, with sync on, either way. A claim about privacy that changes as you toggle
/// something is a claim you have to watch, and the point of one is that you do not, so both
/// endpoints are now named unconditionally.
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
                    own private iCloud database. No account with us, no analytics, no \
                    third-party service: the only two things this app ever talks to are your \
                    own iCloud, and Apple Maps when you type a place into a record. Off means \
                    off for your library — it stays on this Mac and none of it goes anywhere. \
                    A place you search for still reaches Apple Maps, because you asked it to.
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

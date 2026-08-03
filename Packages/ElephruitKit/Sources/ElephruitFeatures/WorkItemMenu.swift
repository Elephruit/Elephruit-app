import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// The context menu every presentation of a work item shares.
///
/// One menu for the list row and the board card, because a right-click is the same question in
/// both places and the two drifting apart is how a bug ended up deletable from one view and not
/// the other. Everything here is a duplicate of an action reachable elsewhere — the sheet, the
/// title field, drag — never the only route to one.
///
/// `services` is passed in rather than read from the environment: a `contextMenu`'s content is
/// hosted outside the row's view tree, and environment values have gone missing there before
/// (see docs/32, §8).
struct WorkItemMenu: View {
    let facts: TaskFacts
    let model: ProjectWorkspaceModel
    let services: AppServices?

    var body: some View {
        Button("Open") { model.present(facts.id) }
        Button("Rename") { model.beginRenaming(facts.id) }

        Divider()

        if facts.status == .completed || facts.status == .cancelled {
            Button("Reopen") { perform { try $0.reminderLifecycle.reopen($1) } }
        } else {
            Button("Mark Complete") { perform { _ = try $0.reminderLifecycle.complete($1) } }
        }

        if facts.kind == .bug {
            Menu("Severity") {
                ForEach(BugSeverity.allCases, id: \.self) { severity in
                    Button {
                        perform { try $0.bugs.setSeverity(severity, on: $1) }
                    } label: {
                        if facts.severity == severity {
                            Label(severity.displayName, systemImage: "checkmark")
                        } else {
                            Text(severity.displayName)
                        }
                    }
                }
            }

            if facts.isVerified {
                Button("Clear Verification") { perform { try $0.bugs.clearVerification($1) } }
            } else {
                Button("Mark Verified") { perform { try $0.bugs.markVerified($1) } }
            }
        }

        Divider()

        Button("Move to Trash", role: .destructive) {
            model.moveToTrash([facts.id])
        }
    }

    private func perform(_ work: (AppServices, Item) throws -> Void) {
        guard let services, let item = model.item(facts.id) else { return }
        guard services.perform({ try work(services, item) }) else { return }
        services.noteChange(to: item)
        model.refresh()
    }
}

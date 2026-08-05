import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import SwiftUI

/// What an entry is filed under, while it is being composed or corrected.
///
/// ### Why identities and not items
/// A view cannot safely hold a `PersistentModel` across a store change, and a sheet is open
/// across exactly the kind of pause where one happens. Ids cross that safely and resolve to
/// items at the moment of the write, which is also the moment a deletion elsewhere becomes
/// visible: an item that has gone by then files as nothing, which is the truth, rather than
/// failing the save.
struct TimeEntryFiling: Equatable {
    var subject: UUID?
    var project: UUID?
    var people: [UUID] = []
    var tagSlugs: [String] = []
    var isBillable = false

    init() {}

    /// The filing an existing entry already has.
    ///
    /// The project is read from the entry's **explicit** one only. Prefilling from a derived
    /// project and saving would pin it, and the entry would stop following its task the next
    /// time that task moved — see `docs/29`, where this cost an editor a rewrite.
    init(_ entry: TimeEntry) {
        subject = entry.item?.id
        project = entry.project?.id
        people = (entry.people ?? []).map(\.id)
        tagSlugs = (entry.tags ?? []).map(\.slug).sorted()
        isBillable = entry.isBillable
    }

    @MainActor
    func item(_ id: UUID, in services: AppServices) -> Item? {
        (try? services.items.item(id: id)) ?? nil
    }
}

/// The filing rows, shared by the sheet that adds time and the sheet that corrects it.
///
/// One view rather than two sets of rows, because the two sheets disagreeing about what can be
/// filed is how an entry added by hand becomes unreportable while the identical entry from a
/// timer is fine.
struct TimeFilingSection: View {
    @Environment(\.services) private var services

    @Binding var filing: TimeEntryFiling

    private enum Field: String, Identifiable {
        case subject, project, people, tags
        var id: String { rawValue }
    }

    @State private var active: Field?

    var body: some View {
        Section {
            row(
                label: "Against",
                value: title(of: filing.subject),
                symbolName: "doc.text",
                identifier: AccessibilityID.Time.subjectPicker
            ) { active = .subject }
                .popover(isPresented: showing(.subject), arrowEdge: .top) {
                    MobileItemPicker(
                        title: "Subject",
                        kinds: [.task, .reminder, .project, .note, .area, .goal],
                        selected: filing.subject,
                        onPick: { filing.subject = $0 }
                    )
                }

            row(
                label: "Project",
                value: title(of: filing.project),
                symbolName: "square.stack.3d.up",
                identifier: AccessibilityID.Time.projectPicker
            ) { active = .project }
                .popover(isPresented: showing(.project), arrowEdge: .top) {
                    MobileItemPicker(
                        title: "Project",
                        kinds: [.project],
                        selected: filing.project,
                        onPick: { filing.project = $0 }
                    )
                }

            row(
                label: "With",
                value: peopleSummary,
                symbolName: "person.2",
                identifier: AccessibilityID.Time.peoplePicker
            ) { active = .people }
                .popover(isPresented: showing(.people), arrowEdge: .top) {
                    MobileParticipantPicker(
                        selected: Set(filing.people),
                        onPick: { filing.people = $0 }
                    )
                }

            row(
                label: "Tags",
                value: filing.tagSlugs.isEmpty ? nil : filing.tagSlugs.joined(separator: " "),
                symbolName: "number",
                identifier: AccessibilityID.Time.tagPicker
            ) { active = .tags }
                .popover(isPresented: showing(.tags), arrowEdge: .top) {
                    MobileTagPicker(selected: $filing.tagSlugs)
                }

            Toggle(isOn: $filing.isBillable) {
                Label("Billable", systemImage: "dollarsign.circle")
            }
            .accessibilityIdentifier(AccessibilityID.Time.billableToggle)
        } header: {
            Text("Filing")
        } footer: {
            // The one thing about this section that is not obvious from its labels, and the one
            // that costs a report its meaning when it is got wrong.
            Text("Time against a task already counts toward that task's project. Set a project here only when it is somewhere else.")
        }
    }

    private func row(
        label: String,
        value: String?,
        symbolName: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Label(label, systemImage: symbolName)
                    .foregroundStyle(Theme.Colors.primaryText)
                Spacer(minLength: Theme.Spacing.small)
                Text(value ?? "None")
                    .foregroundStyle(value == nil ? Theme.Colors.tertiaryText : Theme.Colors.secondaryText)
                    .lineLimit(1)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(value ?? "none")
        .accessibilityIdentifier(identifier)
    }

    private func showing(_ field: Field) -> Binding<Bool> {
        Binding(
            get: { active == field },
            set: { if !$0 { active = nil } }
        )
    }

    private func title(of id: UUID?) -> String? {
        guard let id, let services else { return nil }
        return (try? services.items.item(id: id))??.displayTitle
    }

    private var peopleSummary: String? {
        let names = filing.people.compactMap { title(of: $0) }
        guard let first = names.first else { return nil }
        return names.count == 1 ? first : "\(first) +\(names.count - 1)"
    }
}

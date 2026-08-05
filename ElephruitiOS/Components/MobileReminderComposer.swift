import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import SwiftUI

/// The reminder editor, inline in the list.
///
/// The Mac's composer is 2,000 lines because a desktop composer is a keyboard instrument:
/// eight focus stops, a date search that answers `we` and `8`, popovers, and a traversal order
/// held in a state machine. None of that is what a thumb needs, and porting it would produce a
/// dense grid of controls at 44 points each.
///
/// What survives is the *shape*, which is the part the user recognises: the editor is a card
/// that takes the row's place in the list rather than a sheet that covers the app, so the
/// reminders around the one being written stay legible the whole time — and writing three
/// reminders in a row never costs three presentations. The fields are the same fields, the
/// draft is the same `ReminderComposerDraft`, and the same `ReminderShortcutParser` reads
/// `#tag @person >project` out of the title, so a sentence typed on either machine means the
/// same thing on both.
struct MobileReminderComposer: View {
    @Environment(\.services) private var services

    @Binding var draft: ReminderComposerDraft

    /// Saves and stays open, for writing several in a row.
    var onQuickCommit: () -> Void
    /// Saves and closes.
    var onCommitAndClose: () -> Void
    var onCancel: () -> Void

    @FocusState private var isTitleFocused: Bool
    @State private var vocabulary = CaptureVocabulary.empty
    @State private var editingDate: DateField?

    /// Which of the two dates a picker is currently choosing.
    ///
    /// One piece of state for both, rather than a Boolean each: the two pickers are the same
    /// picker asking a different question, and two flags could both be true.
    private enum DateField: Identifiable {
        case when
        case deadline

        var id: Int { self == .when ? 0 : 1 }
        var title: String { self == .when ? "When" : "Deadline" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            TextField("New reminder", text: $draft.title, axis: .vertical)
                .font(Theme.Text.rowTitle)
                .lineLimit(1...4)
                .focused($isTitleFocused)
                .submitLabel(.done)
                // Return saves and leaves the editor open, which is the Mac's quick commit and
                // the reason a list of eight reminders is eight sentences rather than eight
                // round trips through a sheet.
                .onSubmit(onQuickCommit)
                .accessibilityIdentifier("reminders.composer.title")

            interpretation

            TextField("Notes", text: $draft.notes, axis: .vertical)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .lineLimit(1...6)
                .accessibilityIdentifier("reminders.composer.notes")

            scheduleRow
            actions
        }
        .padding(Theme.Spacing.medium)
        .background(
            Theme.Colors.contentBackground,
            in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.Colors.tintedStroke(Theme.Colors.selection))
        )
        .elevation(.floating)
        .task {
            vocabulary = (try? services?.capture.vocabulary()) ?? .empty
            isTitleFocused = true
        }
        .sheet(item: $editingDate) { field in
            MobileDayPickerSheet(
                title: field.title,
                selection: field == .when ? $draft.startAt : $draft.dueAt
            )
        }
        // `.contain` before the identifier, for the reason the drawer learned it: an identifier
        // on a stack is inherited by every child that has none of its own, so naming the card
        // had renamed the title field, the notes field and both buttons to "reminders.composer"
        // — one element with four bodies, and nothing addressable inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reminders.composer")
    }

    // MARK: - What the sentence was understood to mean

    /// The tags, people and project read out of the title, shown while it is being typed.
    ///
    /// The same reassurance quick capture gives: the grammar is only worth having if you can
    /// see it working, and a `#tag` that silently failed to become a tag is worse than no
    /// grammar at all.
    @ViewBuilder
    private var interpretation: some View {
        let extraction = ReminderShortcutParser.extract(from: draft.title, knowing: vocabulary)
        if !extraction.tagSlugs.isEmpty || !extraction.personNames.isEmpty
            || extraction.projectTitle != nil {
            FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
                if let project = extraction.projectTitle {
                    chip(project, symbol: "folder", tint: Theme.Colors.link)
                }
                ForEach(extraction.personNames, id: \.self) { name in
                    chip(name, symbol: "person", tint: Theme.Colors.link)
                }
                ForEach(extraction.tagSlugs, id: \.self) { slug in
                    chip("#\(slug)", symbol: nil, tint: Theme.Colors.secondaryText)
                }
            }
        }
    }

    // MARK: - When it matters

    private var scheduleRow: some View {
        FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
            dateButton(.when, date: draft.startAt, symbol: "calendar")
            dateButton(.deadline, date: draft.dueAt, symbol: "calendar.badge.exclamationmark")

            Button {
                draft.isSomeday.toggle()
            } label: {
                chip(
                    "Someday",
                    symbol: "archivebox",
                    tint: draft.isSomeday ? Theme.Colors.selection : Theme.Colors.secondaryText,
                    isFilled: draft.isSomeday
                )
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(draft.isSomeday ? .isSelected : [])
            .accessibilityIdentifier("reminders.composer.someday")
        }
    }

    private func dateButton(_ field: DateField, date: Date?, symbol: String) -> some View {
        Button {
            editingDate = field
        } label: {
            chip(
                date.map { resolved in
                    guard let clock = services?.dateProvider else { return field.title }
                    return "\(field.title) \(RelativeDay.text(for: resolved, using: clock))"
                } ?? field.title,
                symbol: symbol,
                tint: date == nil ? Theme.Colors.secondaryText : Theme.Colors.selection,
                isFilled: date != nil
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reminders.composer.\(field.title.lowercased())")
    }

    // MARK: - Committing

    private var actions: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("reminders.composer.cancel")

            Spacer(minLength: 0)

            Button("Done", action: onCommitAndClose)
                .buttonStyle(.borderedProminent)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("reminders.composer.done")
        }
    }

    private func chip(
        _ text: String,
        symbol: String?,
        tint: Color,
        isFilled: Bool = false
    ) -> some View {
        HStack(spacing: Theme.Spacing.hairline) {
            if let symbol {
                Image(systemName: symbol)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(Theme.Text.chip)
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.tight)
        .frame(minHeight: 32)
        .background(
            Capsule().fill(isFilled ? Theme.Colors.tintedFill(tint) : Theme.Colors.subtleFill)
        )
        .contentShape(Capsule())
    }
}

/// One day, chosen.
///
/// A day rather than an instant: every scheduling decision this app makes is about which day
/// something belongs to, and a picker offering 3:47 PM would be offering precision the model
/// does not keep. The quick rows come first because they answer the question most of the time,
/// and the calendar is there for the times they do not.
struct MobileDayPickerSheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let title: String
    @Binding var selection: Date?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    quickRow("Today", daysFromToday: 0)
                    quickRow("Tomorrow", daysFromToday: 1)
                    quickRow("Next week", daysFromToday: 7)
                }

                Section {
                    DatePicker(
                        title,
                        selection: Binding(
                            get: { selection ?? services?.dateProvider.startOfToday ?? Date() },
                            set: { selection = $0 }
                        ),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                }

                if selection != nil {
                    Section {
                        Button("Clear", role: .destructive) {
                            selection = nil
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func quickRow(_ label: String, daysFromToday: Int) -> some View {
        Button(label) {
            selection = services?.dateProvider.startOfDay(daysFromToday: daysFromToday)
            dismiss()
        }
    }
}

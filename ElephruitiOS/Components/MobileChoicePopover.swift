import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// One thing that can be chosen, already reduced to what choosing needs.
///
/// A value type, and the reason is the whole performance story of these lists. The first
/// version held `Item`s and filtered them with
/// `TextNormalizer.foldedForMatching($0.displayTitle).contains(query)` — which, on every
/// keystroke, faulted every record out of the store to read a computed title and allocated a
/// folded copy of it. Here the title is read once, folded once, and every keystroke after that
/// compares plain strings.
struct MobileChoice: Identifiable, Hashable {
    let id: String
    let title: String
    let symbolName: String
    let colorName: String?
    /// The title, case- and diacritic-folded once, for matching.
    let folded: String

    init(id: String, title: String, symbolName: String, colorName: String? = nil) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.colorName = colorName
        self.folded = TextNormalizer.foldedForMatching(title)
    }
}

/// Where a list of choices is being shown, which decides how it behaves.
///
/// The two are the same list with the same rows; what differs is whether a keyboard is coming.
enum MobileChoiceStyle {
    /// A small popup anchored to its control. Tapping only — no field, no keyboard.
    case popover
    /// A sheet that exists because someone wants to type. The field is focused on arrival.
    case search
}

/// A list you choose from: tapping in a popover, typing in a sheet.
///
/// ### Why typing is a different presentation
/// A search field inside a popover looks reasonable and is not: tapping it raises the keyboard,
/// the keyboard shoves the popup somewhere it was not anchored, and what is left of the popup
/// is a few rows above a keyboard covering the list being filtered. The field was a promise the
/// popover could not keep.
///
/// So the popover does not have one. It has the list — which for most tags, most people and
/// nearly every project list is the whole answer, one tap away, with no keyboard at all — and a
/// row that says *Search*. Tapping that closes the popup and opens a sheet built for the
/// keyboard: field at the top, focused on arrival, the full height of the screen beneath it for
/// results. Each presentation does the one thing it is good at.
struct MobileChoiceList: View {
    let title: String
    let choices: [MobileChoice]
    /// Whether more than one can be on at a time.
    let allowsMultiple: Bool
    /// The ids currently chosen.
    let selection: Set<String>
    /// A row the caller adds itself — coining a tag that does not exist yet.
    var coining: ((String) -> MobileChoice?)?
    var onToggle: (MobileChoice) -> Void
    /// Present when the choice can be taken back to nothing.
    var onClear: (() -> Void)?

    var style: MobileChoiceStyle = .popover
    /// Asked for when the popover's Search row is tapped.
    var onRequestSearch: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    /// Below this many rows, searching is slower than looking.
    private static let searchThreshold = 8

    @State private var query = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        switch style {
        case .popover: popoverBody
        case .search: searchBody
        }
    }

    // MARK: - Tapping

    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            clearRow

            if choices.count > Self.searchThreshold, onRequestSearch != nil {
                searchRow
                Divider()
            }

            list
        }
        .padding(.vertical, Theme.Spacing.small)
        .frame(width: 300)
        .frame(maxHeight: 360)
        .presentationCompactAdaptation(.popover)
        // The name the header used to carry, kept for the reading that still needs it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    /// What is left of the header: a way to take the choice back, and only when there is a
    /// choice to take back.
    ///
    /// The title went. A popup anchored to the control that opened it is already labelled by
    /// that control — the word "TAGS" over a list of tags, one tap after tapping the tag button,
    /// is the popup spending its first row telling you what you just did. On a phone that row is
    /// a tenth of the popup and the popup is already short of space.
    @ViewBuilder
    private var clearRow: some View {
        if let onClear, !selection.isEmpty {
            HStack {
                Spacer(minLength: 0)
                Button("Clear", action: onClear)
                    .font(Theme.Text.chip)
                    .accessibilityIdentifier("reminders.picker.clear")
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.bottom, Theme.Spacing.small)
        }
    }

    /// The door to the keyboard, drawn as a row rather than a field.
    ///
    /// It looks like a search field on purpose — that is what it leads to — but it is a button,
    /// because a field here would put a keyboard inside a popup.
    private var searchRow: some View {
        Button {
            onRequestSearch?()
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Text("Search")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search \(title)")
        .accessibilityIdentifier("reminders.picker.searchRow")
    }

    // MARK: - Typing

    private var searchBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.medium) {
                field
                Button("Done") { dismiss() }
                    .font(Theme.Text.rowTitle.weight(.semibold))
                    .accessibilityIdentifier("reminders.picker.done")
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.top, Theme.Spacing.large)
            .padding(.bottom, Theme.Spacing.medium)

            Divider()
            list
        }
        // Large rather than medium: the keyboard takes half a phone, and a medium sheet under a
        // keyboard is a search field with two results below it.
        .presentationDetents([.large])
        .task {
            // A beat after the sheet arrives. Focusing during the presentation animation is how
            // a keyboard ends up half-raised over a sheet that is still sliding up.
            try? await Task.sleep(for: .milliseconds(350))
            isFieldFocused = true
        }
    }

    private var field: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.Colors.tertiaryText)

            TextField("Search \(title.lowercased())", text: $query)
                .font(Theme.Text.rowTitle)
                .focused($isFieldFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .onSubmit { commitFirstMatch() }
                .accessibilityIdentifier("reminders.picker.search")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .frame(minHeight: 44)
        .background(Theme.Colors.subtleFill, in: Capsule())
    }

    // MARK: - Shared parts

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let coined {
                    row(coined, isCoined: true)
                }

                ForEach(matching) { choice in
                    row(choice, isCoined: false)
                }

                if matching.isEmpty && coined == nil {
                    Text(query.isEmpty ? "Nothing to choose from yet." : "No matches.")
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .padding(Theme.Spacing.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func row(_ choice: MobileChoice, isCoined: Bool) -> some View {
        let isOn = selection.contains(choice.id)
        return Button {
            choose(choice)
        } label: {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: isCoined ? "plus.circle" : choice.symbolName)
                    .foregroundStyle(
                        choice.colorName.map { Theme.Palette.color(named: $0) }
                            ?? Theme.Colors.secondaryText
                    )
                    .frame(width: Theme.Size.rowGlyph)

                Text(isCoined ? "Add “\(choice.title)”" : choice.title)
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(Theme.Colors.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isOn {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.Colors.selection)
                }
            }
            .padding(.horizontal, style == .search ? Theme.Spacing.large : Theme.Spacing.medium)
            // The full touch minimum: these are rows aimed at with the phone in one hand.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isOn ? Theme.Colors.selectionFill : .clear)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func choose(_ choice: MobileChoice) {
        onToggle(choice)
        query = ""
        // A single-choice list has nothing left to ask once it has been answered.
        if !allowsMultiple, style == .search { dismiss() }
    }

    private func commitFirstMatch() {
        if let coined {
            choose(coined)
        } else if let first = matching.first {
            choose(first)
        }
    }

    // MARK: - Filtering

    /// Plain string containment over keys folded when the list was built — no model access and
    /// no allocation per row, so it does not get slower as the library gets wider.
    private var matching: [MobileChoice] {
        let wanted = TextNormalizer.foldedForMatching(query)
        guard !wanted.isEmpty else { return choices }
        return choices.filter { $0.folded.contains(wanted) }
    }

    /// The row that makes something that does not exist yet.
    private var coined: MobileChoice? {
        guard let coining, !query.isEmpty else { return nil }
        guard let candidate = coining(query) else { return nil }
        guard !choices.contains(where: { $0.id == candidate.id }) else { return nil }
        return candidate
    }
}

// MARK: - The three lists

/// Tags, with room to coin one.
struct MobileTagPicker: View {
    @Environment(\.services) private var services

    @Binding var selected: [String]
    var style: MobileChoiceStyle = .popover
    var onRequestSearch: (() -> Void)?

    @State private var choices: [MobileChoice] = []

    var body: some View {
        MobileChoiceList(
            title: "Tags",
            choices: choices,
            allowsMultiple: true,
            selection: Set(selected),
            coining: { query in
                let slug = TextNormalizer.slug(query)
                guard TextNormalizer.isValidSlug(slug) else { return nil }
                return MobileChoice(id: slug, title: slug, symbolName: "number")
            },
            onToggle: { choice in
                if let index = selected.firstIndex(of: choice.id) {
                    selected.remove(at: index)
                } else {
                    selected.append(choice.id)
                }
            },
            onClear: { selected.removeAll() },
            style: style,
            onRequestSearch: onRequestSearch
        )
        .task {
            choices = ((try? services?.tags.allTags()) ?? []).map {
                MobileChoice(id: $0.slug, title: $0.slug, symbolName: "number", colorName: $0.colorName)
            }
        }
    }
}

/// People and organisations — the same records the Records module lists.
struct MobilePeoplePicker: View {
    @Environment(\.services) private var services

    @Binding var selected: [String]
    var style: MobileChoiceStyle = .popover
    var onRequestSearch: (() -> Void)?

    @State private var choices: [MobileChoice] = []

    var body: some View {
        MobileChoiceList(
            title: "People",
            choices: choices,
            allowsMultiple: true,
            selection: Set(selected.map { TextNormalizer.foldedForMatching($0) }),
            onToggle: { choice in
                if let index = selected.firstIndex(of: choice.title) {
                    selected.remove(at: index)
                } else {
                    selected.append(choice.title)
                }
            },
            onClear: { selected.removeAll() },
            style: style,
            onRequestSearch: onRequestSearch
        )
        .task {
            // Read once, here, rather than on every keystroke: `displayTitle` walks the model.
            choices = ((try? services?.records.allRecords()) ?? []).map {
                MobileChoice(
                    id: TextNormalizer.foldedForMatching($0.displayTitle),
                    title: $0.displayTitle,
                    symbolName: $0.effectiveSymbolName,
                    colorName: $0.colorName
                )
            }
        }
    }
}

/// One project, or none.
struct MobileProjectPicker: View {
    @Environment(\.services) private var services

    @Binding var selected: String?
    var style: MobileChoiceStyle = .popover
    var onRequestSearch: (() -> Void)?

    @State private var choices: [MobileChoice] = []

    var body: some View {
        MobileChoiceList(
            title: "Project",
            choices: choices,
            allowsMultiple: false,
            selection: Set([selected].compactMap { $0 }),
            onToggle: { choice in
                selected = selected == choice.title ? nil : choice.title
            },
            onClear: { selected = nil },
            style: style,
            onRequestSearch: onRequestSearch
        )
        .task {
            choices = ((try? services?.items.items(matching: ItemQuery.kind(.project))) ?? []).map {
                MobileChoice(
                    id: $0.displayTitle,
                    title: $0.displayTitle,
                    symbolName: "square.stack.3d.up",
                    colorName: $0.colorName
                )
            }
        }
    }
}

// MARK: - Day

/// One day, chosen — the quick answers first, the calendar for when they are not enough.
///
/// A day rather than an instant: every scheduling decision this app makes is about which day
/// something belongs to, and a picker offering 3:47 PM would offer precision the model does not
/// keep. The named rows are on top because they answer the question almost every time, and they
/// are rows rather than a segmented control so a thumb has 44 points to land on. Nothing here
/// needs typing, so this one stays a popover in every case.
///
/// No title and no Clear. Both sat above the first row, and between them they spent the top of a
/// short popup on a word the control already said and a button the card already has: the date is
/// a chip on the composer with an × on it, which is where you look when you want it gone. This
/// opens on "Today", which is the answer most of the time.
struct MobileDayPicker: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let title: String
    @Binding var selection: Date?
    /// Bound only for When: Someday is a kind of when, and a deadline cannot be someday.
    var isSomeday: Binding<Bool>?

    /// Wider than the lists because a month grid has seven columns to fit.
    private static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            quickRow("Today", daysFromToday: 0, symbol: "sun.max")
            quickRow("Tomorrow", daysFromToday: 1, symbol: "sunrise")
            quickRow("Next week", daysFromToday: 7, symbol: "calendar.badge.plus")

            if let isSomeday {
                Button {
                    isSomeday.wrappedValue = true
                    selection = nil
                    dismiss()
                } label: {
                    quickLabel("Someday", symbol: "archivebox", isOn: isSomeday.wrappedValue)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reminders.picker.someday")
            }

            Divider().padding(.vertical, Theme.Spacing.tight)

            DatePicker(
                title,
                selection: Binding(
                    get: { selection ?? services?.dateProvider.startOfToday ?? Date() },
                    set: {
                        selection = $0
                        isSomeday?.wrappedValue = false
                        dismiss()
                    }
                ),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(.horizontal, Theme.Spacing.small)
        }
        .padding(.vertical, Theme.Spacing.small)
        .frame(width: Self.width)
        .presentationCompactAdaptation(.popover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func quickRow(_ label: String, daysFromToday: Int, symbol: String) -> some View {
        let day = services?.dateProvider.startOfDay(daysFromToday: daysFromToday)
        let isOn: Bool = {
            guard let day, let selection, let calendar = services?.dateProvider.calendar else {
                return false
            }
            return calendar.isDate(selection, inSameDayAs: day)
        }()

        return Button {
            selection = day
            isSomeday?.wrappedValue = false
            dismiss()
        } label: {
            quickLabel(label, symbol: symbol, isOn: isOn)
        }
        .buttonStyle(.plain)
    }

    private func quickLabel(_ label: String, symbol: String, isOn: Bool) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(width: Theme.Size.rowGlyph)
            Text(label)
                .font(Theme.Text.rowTitle)
                .foregroundStyle(Theme.Colors.primaryText)
            Spacer(minLength: 0)
            if isOn {
                Image(systemName: "checkmark")
                    .foregroundStyle(Theme.Colors.selection)
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .background(isOn ? Theme.Colors.selectionFill : .clear)
    }
}

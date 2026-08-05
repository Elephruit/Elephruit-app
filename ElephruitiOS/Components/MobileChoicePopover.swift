import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// One thing that can be chosen, already reduced to what choosing needs.
///
/// A value type, and the reason is the whole performance story of these popovers. The first
/// version held `Item`s and filtered them with
/// `TextNormalizer.foldedForMatching($0.displayTitle).contains(query)` — which, on every
/// keystroke, faulted every record out of the store to read a computed title and allocated a
/// folded copy of it. Typing four letters walked the object graph four times. Here the title is
/// read once, folded once, and every keystroke after that compares plain strings.
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

/// A small list you choose from, anchored to the control that opened it.
///
/// ### Tapping before typing
/// The desktop version of this is a query field you type into. That is the right instrument for
/// a keyboard and the wrong one for a thumb: raising the keyboard inside a popup shoves the
/// popup around, covers the list it is filtering, and asks for the slowest input a phone has.
/// So the list comes first and the search field appears only once there are more choices than
/// fit — under that, every option is already on screen and one tap away, and the keyboard never
/// opens at all.
///
/// ### No navigation chrome
/// No `NavigationStack`, no `.searchable`, no Done. Those are a screen's furniture, and this is
/// a popup: it has a title because it needs one, and it closes by being tapped away from.
struct MobileChoicePopover: View {
    /// How many rows can be shown before the list needs a way to narrow itself. Eight 44-point
    /// rows is about a popover's worth of height on the smallest phone this ships to.
    private static let searchThreshold = 8

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

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if showsSearch {
                searchField
                Divider()
            }

            list
        }
        .frame(width: 300)
        // Fixed height only when there is a search field. A list that shrinks as it filters
        // makes the popover resize under the thumb between one keystroke and the next; a short
        // list with no filter has nothing to resize for and should not be padded out to a size
        // it does not need.
        .frame(height: showsSearch ? 360 : nil)
        .presentationCompactAdaptation(.popover)
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(Theme.Text.sectionHeader)
                .kerning(Theme.Text.Tracking.caps)
                .foregroundStyle(Theme.Colors.secondaryText)

            Spacer(minLength: 0)

            if let onClear, !selection.isEmpty {
                Button("Clear", action: onClear)
                    .font(Theme.Text.chip)
                    .accessibilityIdentifier("reminders.picker.clear")
            }
        }
        .textCase(.uppercase)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.top, Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.small)
        .accessibilityAddTraits(.isHeader)
    }

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.Colors.tertiaryText)

            TextField("Filter", text: $query)
                .font(Theme.Text.rowSubtitle)
                .focused($isSearchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .accessibilityIdentifier("reminders.picker.search")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the filter")
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.small)
    }

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
        .scrollIndicators(.automatic)
    }

    private func row(_ choice: MobileChoice, isCoined: Bool) -> some View {
        let isOn = selection.contains(choice.id)
        return Button {
            onToggle(choice)
            if !allowsMultiple { query = "" }
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
            .padding(.horizontal, Theme.Spacing.medium)
            // The full touch minimum. These are the rows a thumb is aiming at while the phone
            // is in one hand, which is the case the desktop's 20-point menu rows never had.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isOn ? Theme.Colors.selectionFill : .clear)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Filtering

    private var showsSearch: Bool {
        choices.count > Self.searchThreshold
    }

    /// Plain string containment over keys folded when the list was built — no model access, no
    /// allocation per row, nothing that gets slower as the library grows wider.
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

    @State private var choices: [MobileChoice] = []

    var body: some View {
        MobileChoicePopover(
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
            onClear: { selected.removeAll() }
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

    @State private var choices: [MobileChoice] = []

    var body: some View {
        MobileChoicePopover(
            title: "People",
            choices: choices,
            allowsMultiple: true,
            selection: Set(selected),
            onToggle: { choice in
                if let index = selected.firstIndex(of: choice.title) {
                    selected.remove(at: index)
                } else {
                    selected.append(choice.title)
                }
            },
            onClear: { selected.removeAll() }
        )
        .task {
            // Read once, here, rather than on every keystroke. `displayTitle` and
            // `effectiveSymbolName` both walk the model; doing that inside a filter is what
            // made typing in this popover feel broken.
            choices = ((try? services?.records.allRecords()) ?? []).map {
                MobileChoice(
                    id: $0.id.uuidString,
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

    @State private var choices: [MobileChoice] = []

    var body: some View {
        MobileChoicePopover(
            title: "Project",
            choices: choices,
            allowsMultiple: false,
            selection: Set([selected].compactMap { $0 }),
            onToggle: { choice in
                selected = selected == choice.title ? nil : choice.title
            },
            onClear: { selected = nil }
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
/// keep. The named rows are on top because they answer the question almost every time, and
/// they are rows rather than a segmented control so a thumb has 44 points to land on.
struct MobileDayPicker: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let title: String
    @Binding var selection: Date?
    /// Bound only for When: Someday is a kind of when, and a deadline cannot be someday.
    var isSomeday: Binding<Bool>?

    /// Wider than the list popovers because a month grid has seven columns to fit.
    private static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

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
        .padding(.bottom, Theme.Spacing.small)
        .frame(width: Self.width)
        .presentationCompactAdaptation(.popover)
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(Theme.Text.sectionHeader)
                .kerning(Theme.Text.Tracking.caps)
                .foregroundStyle(Theme.Colors.secondaryText)

            Spacer(minLength: 0)

            if selection != nil || isSomeday?.wrappedValue == true {
                Button("Clear") {
                    selection = nil
                    isSomeday?.wrappedValue = false
                    dismiss()
                }
                .font(Theme.Text.chip)
                .accessibilityIdentifier("reminders.picker.clear")
            }
        }
        .textCase(.uppercase)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.top, Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.small)
        .accessibilityAddTraits(.isHeader)
    }

    private func quickRow(_ label: String, daysFromToday: Int, symbol: String) -> some View {
        let day = services?.dateProvider.startOfDay(daysFromToday: daysFromToday)
        let isOn = day.map { candidate in
            guard let selection, let calendar = services?.dateProvider.calendar else { return false }
            return calendar.isDate(selection, inSameDayAs: candidate)
        } ?? false

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

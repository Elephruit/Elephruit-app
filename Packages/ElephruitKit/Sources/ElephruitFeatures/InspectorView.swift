import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The trailing inspector: everything about an item that is not its text.
///
/// Kind-aware by construction — it asks ``ItemKind/supportedFields`` what to show, rather than
/// displaying every field and disabling most of them. A note therefore has no greyed-out due-date
/// row, because a note has no due date.
public struct InspectorView: View {
    @Environment(\.services) private var services
    @Environment(\.inspectorPaneWidth) private var paneWidth

    private let navigation: NavigationModel

    @State private var tagInput = ""

    /// Where the selected item could be moved to. Loaded on change, never during a render — see
    /// ``loadPossibleParents(for:)``.
    @State private var possibleParents: [Item] = []

    public init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    /// The event the calendar has selected, when the calendar is what is on screen.
    ///
    /// Read from the focused workspace rather than from `navigation`, because an event is not an
    /// `Item` and giving `selectedItemID` a second meaning would mean every reader of it had to ask
    /// which kind of identifier it was holding.
    @FocusedValue(\.calendarWorkspace) private var calendarWorkspace

    public var body: some View {
        Group {
            if let event = selectedEvent {
                EventInspectorView(event: event) { id in
                    openEventLinkedItem(id)
                }
            } else if let item = currentItem, item.kind == .person {
                // A person's inspector is the contextual pane Records specifies — upcoming
                // events, open promises, related people, stale facts — rather than the generic field
                // editor, whose dates, status, and priority a person has none of.
                RecordContextSidebar(person: item, navigation: navigation)
            } else if let item = currentItem {
                content(for: item)
            } else {
                EmptyStateView(
                    symbolName: "info.circle",
                    headline: "No selection",
                    message: "Select an item to see its details."
                )
            }
        }
        .frame(minWidth: InspectorLayout.minimumWidth)
        .measuresInspectorLayout()
        .accessibilityIdentifier(AccessibilityID.Inspector.root)
        // The two things that can change where this item may be moved to: which item it is, and a
        // write to the library that added or removed a container.
        .task(id: parentCandidatesToken) { loadPossibleParents(for: currentItem) }
    }

    private struct ParentCandidatesToken: Equatable {
        var itemID: UUID?
        var changeToken: Int
    }

    private var parentCandidatesToken: ParentCandidatesToken {
        ParentCandidatesToken(
            itemID: navigation.selectedItemID,
            changeToken: services?.changeToken ?? 0
        )
    }

    /// The selected event, when the calendar destination is showing one.
    private var selectedEvent: CalendarEventSummary? {
        guard navigation.selection == .calendar,
              let id = calendarWorkspace?.selectedEventID,
              let services
        else { return nil }
        return services.calendar.events.first { $0.id == id }
    }

    /// A tagged Record belongs in Records; notes and meeting history keep the established library
    /// route. Without this distinction, clicking a tagged pet or vehicle selected its identifier in
    /// Notes, where it could never be displayed.
    private func openEventLinkedItem(_ id: UUID) {
        if let services, let item = try? services.items.item(id: id),
           item.recordProfile != nil || item.kind == .person {
            navigation.select(.records(.all))
        } else {
            navigation.select(.kind(.note))
        }
        navigation.selectItem(id)
    }

    private func content(for item: Item) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                identitySection(for: item)

                if item.kind.supportsStatus {
                    statusSection(for: item)
                }

                if hasAnyDateField(item.kind) {
                    datesSection(for: item)
                }

                organisationSection(for: item)
                tagsSection(for: item)

                if item.kind.supportedFields.contains(.url) {
                    urlSection(for: item)
                }

                provenanceSection(for: item)

                if !item.userMetadata.isEmpty {
                    metadataSection(for: item)
                }
            }
            .padding(Theme.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Sections

    private func identitySection(for item: Item) -> some View {
        InspectorSection("Item") {
            InspectorRow("Kind") {
                Picker("Kind", selection: kindBinding(for: item)) {
                    ForEach(ItemKind.shippingInMilestoneOne, id: \.self) { kind in
                        Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier(AccessibilityID.Inspector.kindPicker)
            }

            InspectorRow("Flags") {
                HStack(spacing: Theme.Spacing.small) {
                    Toggle(isOn: boolBinding(for: item, keyPath: \.isFavorite)) {
                        Label("Favorite", systemImage: "star")
                    }
                    .toggleStyle(.button)
                    .accessibilityIdentifier(AccessibilityID.Inspector.favoriteToggle)

                    Toggle(isOn: boolBinding(for: item, keyPath: \.isPinned)) {
                        Label("Pinned", systemImage: "pin")
                    }
                    .toggleStyle(.button)
                    .accessibilityIdentifier(AccessibilityID.Inspector.pinToggle)
                }
                .labelStyle(.iconOnly)
            }

            if item.kind.supportedFields.contains(.appearance) {
                InspectorRow("Color") {
                    Picker("Color", selection: colorBinding(for: item)) {
                        Text("Default").tag(String?.none)
                        ForEach(Theme.Palette.allCases, id: \.self) { entry in
                            Text(entry.displayName).tag(String?.some(entry.rawValue))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private func statusSection(for item: Item) -> some View {
        InspectorSection("Status") {
            InspectorRow("State") {
                StatusPicker(
                    selection: statusBinding(for: item),
                    usesSegmentedStyle: InspectorLayout.canUseSegmentedControl(paneWidth: paneWidth)
                )
            }

            if item.kind.supportedFields.contains(.priority) {
                InspectorRow("Priority") {
                    Picker("Priority", selection: priorityBinding(for: item)) {
                        ForEach(Priority.allCases, id: \.self) { priority in
                            Text(priority.displayName).tag(priority)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier(AccessibilityID.Inspector.priorityPicker)
                }
            }

            if let recurrence = item.recurrence {
                InspectorRow("Repeats") {
                    // The rule editor is Phase 2; until then an existing rule is shown, not hidden.
                    Text(recurrence.summary)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
        }
    }

    /// ### One vocabulary for the three dates
    /// This said "Due" and "Defer until" while a task's own pane said "Deadline" and "Start" — two
    /// names for each of two fields, on screen at the same time, which is redesign issue #9. The
    /// words here changed rather than the words there, for two reasons. The task pane's names come
    /// from the scheduling model that the whole module rests on: a *start* says do not ask me until
    /// then, a *deadline* is the only date that can make anything late, and "defer" and "due" say
    /// neither of those things clearly. And this is the surface with fewer readers, so moving it
    /// costs less than moving the one people use every day.
    ///
    /// `deferUntil` keeps its name in the store, where it is a column with a migration behind it.
    /// What a column is called and what a person is told are different questions.
    private func datesSection(for item: Item) -> some View {
        let fields = item.kind.supportedFields

        return InspectorSection("Dates") {
            if fields.contains(.startDate) {
                dateRow("Start", for: item, keyPath: \.startAt, identifier: AccessibilityID.Inspector.startDateField)
            }
            if fields.contains(.dueDate) {
                dateRow("Deadline", for: item, keyPath: \.dueAt, identifier: AccessibilityID.Inspector.dueDateField)
            }
            if fields.contains(.deferDate) {
                dateRow("Hidden until", for: item, keyPath: \.deferUntil, identifier: "inspector.deferDate")
            }

            InspectorRow("Created") {
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        }
    }

    /// A date row with an explicit "no date" state, because clearing a due date must be as easy as
    /// setting one.
    private func dateRow(
        _ label: String,
        for item: Item,
        keyPath: ReferenceWritableKeyPath<Item, Date?>,
        identifier: String
    ) -> some View {
        InspectorRow(label) {
            HStack(spacing: Theme.Spacing.tight) {
                if let date = item[keyPath: keyPath] {
                    DatePicker(
                        label,
                        selection: dateBinding(for: item, keyPath: keyPath, fallback: date),
                        displayedComponents: .date
                    )
                    .labelsHidden()

                    Button {
                        update(item) { $0[keyPath: keyPath] = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .accessibilityLabel("Clear \(label)")
                } else {
                    Button("Add") {
                        update(item) { $0[keyPath: keyPath] = services?.dateProvider.startOfToday ?? Date() }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .accessibilityIdentifier(identifier)
        }
    }

    private func organisationSection(for item: Item) -> some View {
        InspectorSection("Organization") {
            InspectorRow("Inside") {
                Picker("Inside", selection: parentBinding(for: item)) {
                    Text("Nothing").tag(UUID?.none)
                    ForEach(possibleParents, id: \.id) { candidate in
                        Text(candidate.displayTitle).tag(UUID?.some(candidate.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier(AccessibilityID.Inspector.projectPicker)
            }

            if !item.children.isEmpty {
                InspectorRow("Contains") {
                    Button("\(item.children.count) item\(item.children.count == 1 ? "" : "s")") {
                        navigation.select(.item(id: item.id))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func tagsSection(for item: Item) -> some View {
        InspectorSection("Tags") {
            if !item.tagSlugs.isEmpty {
                InspectorRow("Current") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                        ForEach(item.tagSlugs, id: \.self) { slug in
                            HStack {
                                TagChip(slug: slug)
                                Button {
                                    removeTag(slug, from: item)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .accessibilityLabel("Remove tag \(slug)")
                            }
                        }
                    }
                }
            }

            InspectorRow("Add") {
                TextField("tag name", text: $tagInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addTag(to: item) }
                    .accessibilityIdentifier(AccessibilityID.Inspector.tagField)
                    .accessibilityLabel("Add a tag")
            }
        }
    }

    private func urlSection(for item: Item) -> some View {
        InspectorSection("Link") {
            InspectorRow("URL") {
                if let url = item.source.url {
                    // A `Link` opens in the default browser via the OS. The app itself makes no
                    // network request — see `docs/06-privacy-and-entitlements.md`.
                    Link(url.absoluteString, destination: url)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } else {
                    Text("None")
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
        }
    }

    private func provenanceSection(for item: Item) -> some View {
        InspectorSection("Provenance") {
            InspectorRow("Origin") {
                Text(item.source.kind.displayName)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
            if let identifier = item.source.identifier {
                InspectorRow("Detail") {
                    Text(identifier)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            InspectorRow("Identifier") {
                Text(item.id.uuidString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .textSelection(.enabled)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Inspector.provenance)
    }

    /// User-defined fields are shown but not editable in v1: the app never interprets them, and a
    /// half-built editor for arbitrary keys would invite the user to rely on something unfinished.
    private func metadataSection(for item: Item) -> some View {
        InspectorSection("Custom Fields") {
            ForEach(item.userMetadata.keys.sorted(), id: \.self) { key in
                if let value = item.userMetadata[key] {
                    InspectorRow(key) {
                        Text(value.displayString { $0.formatted(date: .abbreviated, time: .omitted) })
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
            }
        }
    }

    // MARK: - Data

    private var currentItem: Item? {
        guard let services, let id = navigation.selectedItemID else { return nil }
        return try? services.items.item(id: id)
    }

    private func hasAnyDateField(_ kind: ItemKind) -> Bool {
        let fields = kind.supportedFields
        return fields.contains(.dueDate) || fields.contains(.startDate) || fields.contains(.deferDate)
    }

    /// Containers this item may legally move into. Filtered by ``ItemKind/canContain(_:)``, so the
    /// picker cannot offer a move that validation would then reject.
    ///
    /// ### Why this is loaded rather than computed where it is used
    /// It was computed inside the picker, and a `Picker`'s contents are built eagerly with the rest
    /// of the body rather than when the menu is opened. So every evaluation of this view fetched
    /// every area, project, task, goal, meeting and daily entry in the library, sorted them by
    /// title, and walked the selected item's descendants — to fill a menu nobody had clicked. The
    /// inspector is on screen while the shell animates, so that ran on frames of a sidebar collapse
    /// and on every module switch, and on a library of any size it is tens of milliseconds each
    /// time. The answer changes when the selection changes or when something is written; those are
    /// the two things this is keyed on.
    private func loadPossibleParents(for item: Item?) {
        // A person gets Records' contextual pane rather than the field editor, so there is
        // no picker to fill and no reason to ask.
        guard let services, let item, item.kind != .person else {
            possibleParents = []
            return
        }

        var query = ItemQuery()
        query.kinds = [.area, .project, .task, .goal, .meeting, .dailyEntry]
        query.sort = .titleAscending

        let candidates = (try? services.items.items(matching: query)) ?? []
        let descendantIDs = descendants(of: item)

        possibleParents = candidates.filter { candidate in
            candidate.id != item.id
                && !descendantIDs.contains(candidate.id)
                && candidate.kind.canContain(item.kind)
        }
    }

    private func descendants(of item: Item) -> Set<UUID> {
        var result: Set<UUID> = []
        var queue = item.children

        while let next = queue.popLast() {
            guard result.insert(next.id).inserted else { continue }
            queue.append(contentsOf: next.children)
        }
        return result
    }

    // MARK: - Bindings

    private func kindBinding(for item: Item) -> Binding<ItemKind> {
        Binding(
            get: { item.kind },
            set: { newKind in
                guard let services, newKind != item.kind else { return }
                services.perform { _ = try services.items.setKind(item, to: newKind) }
                services.noteChange(to: item)
            }
        )
    }

    private func statusBinding(for item: Item) -> Binding<ItemStatus> {
        Binding(
            get: { item.status == .none ? .open : item.status },
            set: { newStatus in
                guard let services else { return }
                services.perform {
                    try services.items.update(item) { subject in
                        subject.status = newStatus
                        // Keeps the completion invariant in one place.
                        subject.completedAt = newStatus == .completed ? services.dateProvider.now : nil
                    }
                }
                services.noteChange(to: item)
            }
        )
    }

    private func priorityBinding(for item: Item) -> Binding<Priority> {
        Binding(
            get: { item.priority },
            set: { newValue in update(item) { $0.priority = newValue } }
        )
    }

    private func colorBinding(for item: Item) -> Binding<String?> {
        Binding(
            get: { item.colorName },
            set: { newValue in update(item) { $0.colorName = newValue } }
        )
    }

    private func boolBinding(for item: Item, keyPath: ReferenceWritableKeyPath<Item, Bool>) -> Binding<Bool> {
        Binding(
            get: { item[keyPath: keyPath] },
            set: { newValue in update(item) { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func dateBinding(
        for item: Item,
        keyPath: ReferenceWritableKeyPath<Item, Date?>,
        fallback: Date
    ) -> Binding<Date> {
        Binding(
            get: { item[keyPath: keyPath] ?? fallback },
            set: { newValue in update(item) { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func parentBinding(for item: Item) -> Binding<UUID?> {
        Binding(
            get: { item.parent?.id },
            set: { newValue in
                guard let services else { return }
                let parent = newValue.flatMap { try? services.items.item(id: $0) }
                services.perform { try services.items.setParent(item, to: parent) }
                services.noteChange(to: item)
            }
        )
    }

    // MARK: - Actions

    private func update(_ item: Item, _ mutate: @escaping (Item) -> Void) {
        guard let services else { return }
        services.perform { try services.items.update(item) { mutate($0) } }
        services.noteChange(to: item)
    }

    private func addTag(to item: Item) {
        guard let services else { return }
        let name = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        var slugs = item.tagSlugs
        slugs.append(name)

        services.perform { try services.items.setTags(item, slugs: slugs) }
        services.noteChange(to: item)
        tagInput = ""
    }

    private func removeTag(_ slug: String, from item: Item) {
        guard let services else { return }
        let remaining = item.tagSlugs.filter { $0 != slug }
        services.perform { try services.items.setTags(item, slugs: remaining) }
        services.noteChange(to: item)
    }
}

#Preview("Inspector", traits: .fixedLayout(width: 300, height: 700)) {
    let services = AppServices.inMemory()
    let navigation = NavigationModel()
    navigation.selectItem((try? services.items.items(matching: .kind(.task)))?.first?.id)

    return InspectorView(navigation: navigation)
        .appServices(services)
        .frame(width: 300, height: 700)
}

/// The status control, in whichever form fits.
///
/// A three-way segmented control needs roughly 220pt and does not shrink below its intrinsic size —
/// it clips, which is exactly what the previous inspector did to "Canceled". Below that width it
/// becomes a menu, which is a control that genuinely adapts. Two branches rather than a conditional
/// style, because `.segmented` and `.menu` are different types.
private struct StatusPicker: View {
    @Binding var selection: ItemStatus
    let usesSegmentedStyle: Bool

    private static let choices: [ItemStatus] = [.open, .completed, .cancelled]

    var body: some View {
        Group {
            if usesSegmentedStyle {
                picker.pickerStyle(.segmented)
            } else {
                picker.pickerStyle(.menu)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Inspector.statusPicker)
    }

    private var picker: some View {
        Picker("State", selection: $selection) {
            ForEach(Self.choices, id: \.self) { status in
                Text(status.displayName).tag(status)
            }
        }
        .labelsHidden()
    }
}

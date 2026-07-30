import EverythingCore
import EverythingDesign
import EverythingModel
import EverythingPersistence
import SwiftUI

/// The trailing inspector: everything about an item that is not its text.
///
/// Kind-aware by construction — it asks ``ItemKind/supportedFields`` what to show, rather than
/// displaying every field and disabling most of them. A note therefore has no greyed-out due-date
/// row, because a note has no due date.
public struct InspectorView: View {
    @Environment(\.services) private var services
    private let navigation: NavigationModel

    @State private var tagInput = ""

    public init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    public var body: some View {
        Group {
            if let item = currentItem {
                content(for: item)
            } else {
                EmptyStateView(
                    symbolName: "info.circle",
                    headline: "No selection",
                    message: "Select an item to see its details."
                )
            }
        }
        .frame(minWidth: Theme.Size.inspectorWidth)
        .accessibilityIdentifier(AccessibilityID.Inspector.root)
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
                        Label("Favourite", systemImage: "star")
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
                InspectorRow("Colour") {
                    Picker("Colour", selection: colorBinding(for: item)) {
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
                Picker("State", selection: statusBinding(for: item)) {
                    ForEach([ItemStatus.open, .completed, .cancelled], id: \.self) { status in
                        Text(status.displayName).tag(status)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityIdentifier(AccessibilityID.Inspector.statusPicker)
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

    private func datesSection(for item: Item) -> some View {
        let fields = item.kind.supportedFields

        return InspectorSection("Dates") {
            if fields.contains(.startDate) {
                dateRow("Start", for: item, keyPath: \.startAt, identifier: AccessibilityID.Inspector.startDateField)
            }
            if fields.contains(.dueDate) {
                dateRow("Due", for: item, keyPath: \.dueAt, identifier: AccessibilityID.Inspector.dueDateField)
            }
            if fields.contains(.deferDate) {
                dateRow("Defer until", for: item, keyPath: \.deferUntil, identifier: "inspector.deferDate")
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
        InspectorSection("Organisation") {
            InspectorRow("Inside") {
                Picker("Inside", selection: parentBinding(for: item)) {
                    Text("Nothing").tag(UUID?.none)
                    ForEach(possibleParents(for: item), id: \.id) { candidate in
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
    private func possibleParents(for item: Item) -> [Item] {
        guard let services else { return [] }

        var query = ItemQuery()
        query.kinds = [.area, .project, .task, .goal, .meeting, .dailyEntry]
        query.sort = .titleAscending

        let candidates = (try? services.items.items(matching: query)) ?? []
        let descendantIDs = descendants(of: item)

        return candidates.filter { candidate in
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
    navigation.selectedItemID = (try? services.items.items(matching: .kind(.task)))?.first?.id

    return InspectorView(navigation: navigation)
        .appServices(services)
        .frame(width: 300, height: 700)
}

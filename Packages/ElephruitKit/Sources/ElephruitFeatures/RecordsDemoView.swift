import ElephruitDesign
import SwiftUI

/// A reviewable product prototype for one workspace that can describe any real-world subject.
///
/// This view is intentionally backed by local values rather than SwiftData. The existing People
/// module remains the source of truth while the shared information architecture is evaluated.
struct RecordsDemoView: View {
    @State private var records = RecordsDemoData.records
    @State private var selection = RecordsDemoData.records[0].id
    @State private var typeFilter: DemoRecordType?
    @State private var searchText = ""
    @State private var tab: DemoRecordTab = .overview
    @State private var capture: DemoCapture?

    var body: some View {
        HStack(spacing: 0) {
            recordBrowser
                .frame(width: 292)

            Divider()

            if let record = selectedRecord {
                recordWorkspace(record)
            }
        }
        .background(Theme.Colors.contentBackground)
        .sheet(item: $capture) { capture in
            DemoCaptureSheet(capture: capture) { text in
                applyCapture(capture, text: text)
            }
        }
        .accessibilityIdentifier("records.demo")
    }

    // MARK: Browser

    private var recordBrowser: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                HStack {
                    VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                        Text("People & Things")
                            .font(Theme.Text.title)
                        Text("One place for anything you keep track of")
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }

                    Spacer()

                    Button("New record", systemImage: "plus") {}
                        .labelStyle(.iconOnly)
                        .help("Add a person, pet, vehicle, or another kind of record")
                }

                TextField("Search records", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                typePicker
            }
            .padding(Theme.Spacing.large)

            Divider()

            ScrollView {
                LazyVStack(spacing: Theme.Spacing.tight) {
                    ForEach(filteredRecords) { record in
                        recordRow(record)
                    }
                }
                .padding(Theme.Spacing.small)
            }

            Divider()

            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(Theme.Colors.secondaryText)
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text("Household")
                        .font(Theme.Text.rowTitle)
                    Text("2 people · 1 pet · 1 vehicle")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
            .padding(Theme.Spacing.large)
            .help("Groups can contain different record types")
        }
        .background(.regularMaterial)
    }

    private var typePicker: some View {
        HStack(spacing: Theme.Spacing.tight) {
            filterButton(title: "All", symbol: "circle.grid.2x2", type: nil)
            ForEach(DemoRecordType.allCases) { type in
                filterButton(title: type.shortName, symbol: type.symbolName, type: type)
            }
        }
    }

    private func filterButton(title: String, symbol: String, type: DemoRecordType?) -> some View {
        let isSelected = typeFilter == type
        return Button {
            typeFilter = type
        } label: {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.tight)
                .background(isSelected ? Theme.Colors.selection : Theme.Colors.subtleFill)
                .foregroundStyle(isSelected ? Theme.Colors.onAccent : Theme.Colors.secondaryText)
                .clipShape(.rect(cornerRadius: Theme.Radius.medium))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func recordRow(_ record: DemoRecord) -> some View {
        let isSelected = selection == record.id
        return Button {
            selection = record.id
            tab = .overview
        } label: {
            HStack(spacing: Theme.Spacing.medium) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Theme.Colors.onAccent.opacity(0.18) : Theme.Colors.subtleFill)
                    Image(systemName: record.type.symbolName)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text(record.name)
                        .font(Theme.Text.rowTitleEmphasised)
                        .lineLimit(1)
                    Text(record.subtitle)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(isSelected ? Theme.Colors.onAccent.opacity(0.85) : Theme.Colors.secondaryText)
                        .lineLimit(1)
                    Text(record.statusLine)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(isSelected ? Theme.Colors.onAccent.opacity(0.72) : Theme.Colors.tertiaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if record.attentionCount > 0 {
                    Text("\(record.attentionCount)")
                        .font(Theme.Text.metadata)
                        .padding(.horizontal, Theme.Spacing.small)
                        .padding(.vertical, Theme.Spacing.hairline)
                        .background(isSelected ? Theme.Colors.onAccent.opacity(0.18) : Theme.Colors.subtleFill)
                        .clipShape(.capsule)
                }
            }
            .padding(Theme.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background(isSelected ? Theme.Colors.selection : Color.clear)
            .foregroundStyle(isSelected ? Theme.Colors.onAccent : Theme.Colors.primaryText)
            .clipShape(.rect(cornerRadius: Theme.Radius.medium))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(record.name), \(record.type.displayName), \(record.statusLine)")
    }

    // MARK: Workspace

    private func recordWorkspace(_ record: DemoRecord) -> some View {
        VStack(spacing: 0) {
            recordHeader(record)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    switch tab {
                    case .overview:
                        overview(record)
                    case .timeline:
                        timeline(record)
                    case .relationships:
                        relationships(record)
                    }
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(Theme.Spacing.section)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func recordHeader(_ record: DemoRecord) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            HStack(alignment: .center, spacing: Theme.Spacing.large) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.large)
                        .fill(Theme.Colors.subtleFill)
                    Image(systemName: record.type.symbolName)
                        .font(.system(.title, weight: .medium))
                        .foregroundStyle(Theme.Colors.selection)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    HStack(spacing: Theme.Spacing.small) {
                        Text(record.name)
                            .font(.system(.title, design: .default, weight: .semibold))
                        Text(record.type.displayName)
                            .font(Theme.Text.chip)
                            .padding(.horizontal, Theme.Spacing.small)
                            .padding(.vertical, Theme.Spacing.hairline)
                            .background(Theme.Colors.subtleFill)
                            .clipShape(.capsule)
                    }
                    Text(record.subtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    HStack(spacing: Theme.Spacing.medium) {
                        Label(record.statusLine, systemImage: record.statusSymbol)
                        ForEach(record.tags, id: \.self) { tag in
                            Text("#\(tag)")
                        }
                    }
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                }

                Spacer()

                HStack(spacing: Theme.Spacing.small) {
                    Button("Add note", systemImage: "note.text.badge.plus") {
                        capture = DemoCapture(recordID: record.id, kind: .note)
                    }
                    Button("Log activity", systemImage: "clock.arrow.circlepath") {
                        capture = DemoCapture(recordID: record.id, kind: .activity)
                    }
                    Button("Talking point", systemImage: "bubble.left.and.text.bubble.right") {
                        capture = DemoCapture(recordID: record.id, kind: .talkingPoint)
                    }
                }
            }

            HStack(spacing: Theme.Spacing.tight) {
                ForEach(DemoRecordTab.allCases) { candidate in
                    Button {
                        tab = candidate
                    } label: {
                        Label(candidate.title, systemImage: candidate.symbolName)
                            .padding(.horizontal, Theme.Spacing.medium)
                            .padding(.vertical, Theme.Spacing.small)
                            .background(tab == candidate ? Theme.Colors.selection : Color.clear)
                            .foregroundStyle(tab == candidate ? Theme.Colors.onAccent : Theme.Colors.secondaryText)
                            .clipShape(.rect(cornerRadius: Theme.Radius.medium))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(Theme.Spacing.section)
        .background(Theme.Colors.windowBackground)
    }

    @ViewBuilder
    private func overview(_ record: DemoRecord) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.section) {
            VStack(spacing: Theme.Spacing.section) {
                DemoSectionCard(title: "Next up", symbol: "arrow.right.circle") {
                    ForEach(record.nextUp) { item in
                        DemoLabeledRow(symbol: item.symbol, title: item.title, detail: item.detail)
                    }
                }

                DemoSectionCard(title: record.type == .person ? "Talking points" : "Things to remember", symbol: "bubble.left.and.text.bubble.right") {
                    if record.talkingPoints.isEmpty {
                        Text("Nothing queued.")
                            .foregroundStyle(Theme.Colors.secondaryText)
                    } else {
                        ForEach(record.talkingPoints, id: \.self) { point in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                                Image(systemName: "circle")
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.selection)
                                Text(point)
                                Spacer()
                            }
                        }
                    }
                }

                DemoSectionCard(title: "Open work", symbol: "checklist") {
                    ForEach(record.work) { item in
                        DemoLabeledRow(symbol: item.symbol, title: item.title, detail: item.detail)
                    }
                }
            }

            VStack(spacing: Theme.Spacing.section) {
                DemoSectionCard(title: "Details", symbol: "list.bullet.rectangle") {
                    ForEach(record.facts) { fact in
                        HStack(alignment: .firstTextBaseline) {
                            Text(fact.label)
                                .foregroundStyle(Theme.Colors.secondaryText)
                            Spacer(minLength: Theme.Spacing.large)
                            Text(fact.value)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                DemoSectionCard(title: "Connections", symbol: "point.3.connected.trianglepath.dotted") {
                    ForEach(record.relationships.prefix(3)) { relationship in
                        DemoLabeledRow(
                            symbol: relationship.symbol,
                            title: relationship.name,
                            detail: relationship.label
                        )
                    }
                    Button("See relationship view") { tab = .relationships }
                        .buttonStyle(.link)
                }

                DemoSectionCard(title: "Recent", symbol: "clock") {
                    ForEach(record.timeline.prefix(3)) { event in
                        DemoLabeledRow(symbol: event.symbol, title: event.title, detail: event.detail)
                    }
                    Button("See full timeline") { tab = .timeline }
                        .buttonStyle(.link)
                }
            }
            .frame(width: 350)
        }
    }

    private func timeline(_ record: DemoRecord) -> some View {
        DemoSectionCard(title: "Everything connected to \(record.name)", symbol: "clock.arrow.circlepath") {
            ForEach(record.timeline) { event in
                HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                    Image(systemName: event.symbol)
                        .frame(width: Theme.Size.rowGlyph)
                        .foregroundStyle(Theme.Colors.selection)
                    VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                        Text(event.title)
                            .font(Theme.Text.rowTitleEmphasised)
                        Text(event.detail)
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                        if let note = event.note {
                            Text(note)
                                .padding(.top, Theme.Spacing.tight)
                        }
                    }
                    Spacer()
                    Text(event.when)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .padding(.vertical, Theme.Spacing.tight)
            }
        }
    }

    private func relationships(_ record: DemoRecord) -> some View {
        VStack(spacing: Theme.Spacing.section) {
            DemoSectionCard(title: "Relationship view", symbol: "point.3.connected.trianglepath.dotted") {
                VStack(spacing: Theme.Spacing.large) {
                    demoNode(name: record.name, detail: record.type.displayName, symbol: record.type.symbolName, isPrimary: true)

                    Image(systemName: "arrow.up.and.down")
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    HStack(alignment: .top, spacing: Theme.Spacing.large) {
                        ForEach(record.relationships) { relationship in
                            VStack(spacing: Theme.Spacing.small) {
                                demoNode(
                                    name: relationship.name,
                                    detail: relationship.typeName,
                                    symbol: relationship.symbol,
                                    isPrimary: false
                                )
                                Text(relationship.label)
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.large)
            }

            DemoSectionCard(title: "Why this is one system", symbol: "square.stack.3d.up") {
                Text("The same relationship can connect any two records: a person owns a pet, a pet visits a clinic, a vehicle belongs to a household, or two people work together. Types change the available labels and fields; they do not create separate modules.")
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        }
    }

    private func demoNode(name: String, detail: String, symbol: String, isPrimary: Bool) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: symbol)
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(name).font(Theme.Text.rowTitleEmphasised)
                Text(detail).font(Theme.Text.metadata)
            }
        }
        .padding(Theme.Spacing.medium)
        .background(isPrimary ? Theme.Colors.selection : Theme.Colors.subtleFill)
        .foregroundStyle(isPrimary ? Theme.Colors.onAccent : Theme.Colors.primaryText)
        .clipShape(.rect(cornerRadius: Theme.Radius.large))
    }

    // MARK: State

    private var selectedRecord: DemoRecord? {
        records.first { $0.id == selection }
    }

    private var filteredRecords: [DemoRecord] {
        records.filter { record in
            (typeFilter == nil || record.type == typeFilter)
                && (searchText.isEmpty
                    || record.name.localizedCaseInsensitiveContains(searchText)
                    || record.subtitle.localizedCaseInsensitiveContains(searchText)
                    || record.tags.contains { $0.localizedCaseInsensitiveContains(searchText) })
        }
    }

    private func applyCapture(_ capture: DemoCapture, text: String) {
        guard let index = records.firstIndex(where: { $0.id == capture.recordID }) else { return }
        switch capture.kind {
        case .talkingPoint:
            records[index].talkingPoints.insert(text, at: 0)
        case .activity:
            records[index].timeline.insert(
                DemoTimelineEvent(
                    symbol: "clock.arrow.circlepath",
                    title: text,
                    detail: "Activity · added in the demo",
                    when: "Now"
                ),
                at: 0
            )
        case .note:
            records[index].timeline.insert(
                DemoTimelineEvent(
                    symbol: "note.text",
                    title: text,
                    detail: "Note · linked to \(records[index].name)",
                    when: "Now"
                ),
                at: 0
            )
        }
    }
}

// MARK: - Demo components

private struct DemoSectionCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Label(title, systemImage: symbol)
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(Theme.Colors.secondaryText)

            content
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.windowBackground)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .stroke(Theme.Colors.separator, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: Theme.Radius.large))
    }
}

private struct DemoLabeledRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Image(systemName: symbol)
                .frame(width: Theme.Size.rowGlyph)
                .foregroundStyle(Theme.Colors.selection)
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(title)
                Text(detail)
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct DemoCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss

    let capture: DemoCapture
    let onSave: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            Text(capture.kind.title)
                .font(Theme.Text.title)
            Text(capture.kind.prompt)
                .foregroundStyle(Theme.Colors.secondaryText)
            TextField(capture.kind.placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 430)
    }
}

// MARK: - Demo values

private enum DemoRecordType: String, CaseIterable, Identifiable {
    case person
    case pet
    case vehicle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .person: "Person"
        case .pet: "Pet"
        case .vehicle: "Vehicle"
        }
    }

    var shortName: String {
        switch self {
        case .person: "People"
        case .pet: "Pets"
        case .vehicle: "Cars"
        }
    }

    var symbolName: String {
        switch self {
        case .person: "person.crop.circle"
        case .pet: "pawprint.fill"
        case .vehicle: "car.fill"
        }
    }
}

private enum DemoRecordTab: String, CaseIterable, Identifiable {
    case overview
    case timeline
    case relationships

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbolName: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .timeline: "clock.arrow.circlepath"
        case .relationships: "point.3.connected.trianglepath.dotted"
        }
    }
}

private struct DemoCapture: Identifiable {
    enum Kind {
        case note
        case activity
        case talkingPoint

        var title: String {
            switch self {
            case .note: "Add a linked note"
            case .activity: "Log an activity"
            case .talkingPoint: "Add a talking point"
            }
        }

        var prompt: String {
            switch self {
            case .note: "The note will appear in this record's timeline."
            case .activity: "Record a conversation, visit, service, or other event."
            case .talkingPoint: "Keep something visible until the next conversation or appointment."
            }
        }

        var placeholder: String {
            switch self {
            case .note: "What do you want to remember?"
            case .activity: "What happened?"
            case .talkingPoint: "What do you want to bring up?"
            }
        }
    }

    let id = UUID()
    let recordID: UUID
    let kind: Kind
}

private struct DemoRecord: Identifiable {
    let id = UUID()
    let type: DemoRecordType
    let name: String
    let subtitle: String
    let statusLine: String
    let statusSymbol: String
    let tags: [String]
    let attentionCount: Int
    let nextUp: [DemoListItem]
    var talkingPoints: [String]
    let work: [DemoListItem]
    let facts: [DemoFact]
    let relationships: [DemoRelationship]
    var timeline: [DemoTimelineEvent]
}

private struct DemoListItem: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let detail: String
}

private struct DemoFact: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

private struct DemoRelationship: Identifiable {
    let id = UUID()
    let symbol: String
    let name: String
    let typeName: String
    let label: String
}

private struct DemoTimelineEvent: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let detail: String
    let when: String
    var note: String?

    init(symbol: String, title: String, detail: String, when: String, note: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.when = when
        self.note = note
    }
}

private enum RecordsDemoData {
    static let records: [DemoRecord] = [
        DemoRecord(
            type: .person,
            name: "Maya Chen",
            subtitle: "Product designer · Austin",
            statusLine: "Meeting tomorrow · spoke 6 days ago",
            statusSymbol: "video",
            tags: ["family", "design"],
            attentionCount: 3,
            nextUp: [
                DemoListItem(symbol: "video", title: "Quarterly catch-up", detail: "Tomorrow at 10:00 AM · Video"),
                DemoListItem(symbol: "birthday.cake", title: "Birthday", detail: "September 18"),
            ],
            talkingPoints: [
                "Ask how the new team structure is working",
                "Recommend the contractor Jordan used",
            ],
            work: [
                DemoListItem(symbol: "arrow.up.right", title: "Send contractor recommendation", detail: "I owe Maya · due Friday"),
                DemoListItem(symbol: "arrow.down.left", title: "Pricing deck feedback", detail: "Waiting on Maya · follow up Monday"),
            ],
            facts: [
                DemoFact(label: "Phone", value: "(512) 555-0148"),
                DemoFact(label: "Email", value: "maya@example.com"),
                DemoFact(label: "Time zone", value: "Central"),
                DemoFact(label: "Partner", value: "Jordan Lee"),
            ],
            relationships: [
                DemoRelationship(symbol: "person.crop.circle", name: "Jordan Lee", typeName: "Person", label: "Partner"),
                DemoRelationship(symbol: "pawprint.fill", name: "Pepper", typeName: "Pet", label: "Owner"),
                DemoRelationship(symbol: "person.crop.circle", name: "Nisha Patel", typeName: "Person", label: "Introduced by"),
            ],
            timeline: [
                DemoTimelineEvent(symbol: "message.fill", title: "Texted about the Austin move", detail: "Conversation · with Maya", when: "Jul 28", note: "She is excited about the neighborhood but still sorting out the commute."),
                DemoTimelineEvent(symbol: "note.text", title: "Design leadership notes", detail: "Note · #design", when: "Jul 14"),
                DemoTimelineEvent(symbol: "checkmark.circle", title: "Sent portfolio introduction", detail: "Completed work · related to Maya", when: "Jun 30"),
                DemoTimelineEvent(symbol: "person.2.fill", title: "Lunch at Loro", detail: "In person · with Maya and Jordan", when: "Jun 12"),
            ]
        ),
        DemoRecord(
            type: .pet,
            name: "Pepper",
            subtitle: "Mini Australian Shepherd · 6 years old",
            statusLine: "Medication Friday · vet Sep 12",
            statusSymbol: "cross.case",
            tags: ["household", "dog"],
            attentionCount: 2,
            nextUp: [
                DemoListItem(symbol: "pills.fill", title: "Simparica Trio", detail: "Friday · repeats monthly"),
                DemoListItem(symbol: "cross.case", title: "Annual wellness visit", detail: "September 12 at 2:30 PM"),
            ],
            talkingPoints: [
                "Ask the vet about increased paw licking",
                "Confirm whether the dosage changes at 40 lb",
            ],
            work: [
                DemoListItem(symbol: "pills", title: "Refill heartworm medication", detail: "Related to Pepper · due Thursday"),
                DemoListItem(symbol: "doc.text", title: "Upload vaccination certificate", detail: "Related to Pepper · open"),
            ],
            facts: [
                DemoFact(label: "Breed", value: "Mini Australian Shepherd"),
                DemoFact(label: "Birthday", value: "March 4, 2020"),
                DemoFact(label: "Weight", value: "38.2 lb · Jul 18"),
                DemoFact(label: "Microchip", value: "985141000842771"),
                DemoFact(label: "Medication", value: "Simparica Trio · monthly"),
            ],
            relationships: [
                DemoRelationship(symbol: "person.crop.circle", name: "Maya Chen", typeName: "Person", label: "Owned by"),
                DemoRelationship(symbol: "cross.case", name: "Dr. Lena Ortiz", typeName: "Person", label: "Veterinarian"),
                DemoRelationship(symbol: "building.2", name: "South Congress Vet", typeName: "Organization", label: "Clinic"),
            ],
            timeline: [
                DemoTimelineEvent(symbol: "pills.fill", title: "Simparica Trio given", detail: "Medication · recurring care", when: "Jul 31"),
                DemoTimelineEvent(symbol: "scalemass", title: "Weight recorded: 38.2 lb", detail: "Health measurement", when: "Jul 18"),
                DemoTimelineEvent(symbol: "cross.case.fill", title: "Vaccination visit", detail: "Appointment · South Congress Vet", when: "Mar 8", note: "Rabies and DHPP renewed. No reactions after the visit."),
                DemoTimelineEvent(symbol: "paperclip", title: "Vaccination certificate", detail: "PDF attachment", when: "Mar 8"),
            ]
        ),
        DemoRecord(
            type: .vehicle,
            name: "Honda CR-V",
            subtitle: "2021 EX-L · Lunar Silver",
            statusLine: "48,220 mi · service due in 1,780 mi",
            statusSymbol: "wrench.and.screwdriver",
            tags: ["household", "daily-driver"],
            attentionCount: 1,
            nextUp: [
                DemoListItem(symbol: "wrench.and.screwdriver", title: "50,000-mile service", detail: "Due in 1,780 miles"),
                DemoListItem(symbol: "calendar", title: "Registration renewal", detail: "October 31"),
            ],
            talkingPoints: [
                "Ask whether the brake vibration is covered by the service plan",
            ],
            work: [
                DemoListItem(symbol: "wind", title: "Replace cabin air filter", detail: "Related to Honda CR-V · this weekend"),
                DemoListItem(symbol: "doc.text", title: "Compare insurance renewal", detail: "Related to Honda CR-V · due Sep 20"),
            ],
            facts: [
                DemoFact(label: "VIN", value: "7FARW2H89ME012846"),
                DemoFact(label: "Mileage", value: "48,220 mi · Jul 29"),
                DemoFact(label: "Plate", value: "TX RCF-2184"),
                DemoFact(label: "Tires", value: "Michelin CrossClimate 2"),
                DemoFact(label: "Oil", value: "0W-20 synthetic"),
            ],
            relationships: [
                DemoRelationship(symbol: "person.crop.circle", name: "Maya Chen", typeName: "Person", label: "Owned by"),
                DemoRelationship(symbol: "house.fill", name: "Household", typeName: "Group", label: "Belongs to"),
                DemoRelationship(symbol: "wrench.and.screwdriver", name: "Rising Sun Automotive", typeName: "Organization", label: "Serviced by"),
            ],
            timeline: [
                DemoTimelineEvent(symbol: "gauge.with.dots.needle.67percent", title: "Mileage recorded: 48,220", detail: "Vehicle measurement", when: "Jul 29"),
                DemoTimelineEvent(symbol: "wrench.and.screwdriver.fill", title: "Oil and filter change", detail: "Maintenance · Rising Sun Automotive", when: "May 22", note: "46,104 miles. Synthetic oil. Technician noted front brake pads at 6 mm."),
                DemoTimelineEvent(symbol: "paperclip", title: "Service receipt", detail: "PDF attachment · $118.42", when: "May 22"),
                DemoTimelineEvent(symbol: "car.side.fill", title: "Four new tires", detail: "Maintenance · Discount Tire", when: "Jan 10"),
            ]
        ),
    ]
}

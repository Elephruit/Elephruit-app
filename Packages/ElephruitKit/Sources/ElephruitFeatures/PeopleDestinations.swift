import ElephruitCore
import ElephruitDesign
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Celebrations

/// Birthdays, anniversaries, memorials, and whatever the user has decided to mark.
///
/// A dedicated view rather than a filter on the people list, because the question is temporal — what
/// is coming up — and a list sorted by name answers it badly.
struct CelebrationsView: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel

    @State private var upcoming: [UpcomingCelebration] = []
    @State private var horizonDays = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Celebrations")
                    .font(Theme.Text.title)
                Spacer()
                Picker("Ahead", selection: $horizonDays) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("A year").tag(365)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("How far ahead to look")
            }
            .padding(Theme.Spacing.medium)

            Divider()

            if upcoming.isEmpty {
                EmptyStateView(
                    symbolName: "birthday.cake",
                    headline: "Nothing coming up",
                    message: """
                        Record a birthday or an anniversary on somebody's page and it will appear \
                        here. A birthday with no year is fine — the day is what matters.
                        """
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                        ForEach(months, id: \.month) { group in
                            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                                Text(group.month.formatted(.dateTime.month(.wide).year()))
                                    .font(Theme.Text.sectionHeader)
                                    .foregroundStyle(Theme.Colors.secondaryText)

                                ForEach(group.celebrations) { entry in
                                    CelebrationRow(entry: entry) { navigation.selectItem($0) }
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.medium)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.People.celebrations)
        .task(id: horizonDays) { reload() }
    }

    private var months: [(month: Date, celebrations: [UpcomingCelebration])] {
        CelebrationCalendar.byMonth(upcoming, calendar: services?.dateProvider.calendar ?? .autoupdatingCurrent)
    }

    private func reload() {
        guard let services else { return }
        let all = (try? services.persons.allCelebrations()) ?? []
        upcoming = CelebrationCalendar.upcoming(
            from: all,
            within: horizonDays,
            asOf: services.dateProvider.now,
            calendar: services.dateProvider.calendar
        )
    }
}

struct CelebrationRow: View {
    @Environment(\.services) private var services

    let entry: UpcomingCelebration
    let onOpen: (UUID) -> Void

    @State private var giftIdeas: [String] = []

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Image(systemName: entry.celebration.kind.symbolName)
                .foregroundStyle(entry.isImminent ? Theme.Colors.dueToday : Theme.Colors.secondaryText)
                .frame(width: Theme.Size.rowGlyph)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                Button {
                    onOpen(entry.celebration.personID)
                } label: {
                    Text(entry.summary)
                        .font(entry.isImminent ? Theme.Text.rowTitleEmphasised : Theme.Text.rowTitle)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)

                Text(entry.occursOn.formatted(date: .complete, time: .omitted))
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)

                if entry.isShiftedFromLeapDay {
                    Label("Born on 29 February — shown on the 28th this year.", systemImage: "calendar.badge.exclamationmark")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }

                // Gift ideas, but never on a memorial. An app that suggests buying a present on the
                // anniversary of a death has failed at the only thing this module is for.
                if entry.celebration.kind.isCelebratory, !giftIdeas.isEmpty {
                    Label(giftIdeas.joined(separator: " · "), systemImage: "gift")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.tight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.summary), \(entry.occursOn.formatted(date: .complete, time: .omitted))")
        .task { loadGiftIdeas() }
    }

    private func loadGiftIdeas() {
        guard let services,
              entry.celebration.kind.isCelebratory,
              let person = try? services.persons.person(id: entry.celebration.personID),
              let ledger = try? services.persons.ledger(for: person)
        else { return }
        giftIdeas = ledger.current(.giftIdea).map(\.value)
    }
}

// MARK: - My Card

/// The user's own identity, and what they hand out.
///
/// ### Why sharing profiles are chosen in advance
/// The decision "what does this person get" is made once per audience, not once per encounter.
/// Choosing calmly beforehand beats choosing in the two seconds before a QR code is scanned, and it
/// is why the minimal profile is genuinely minimal — a name and one way to reply.
struct MyCardView: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel

    @State private var profileID: UUID?
    @State private var isExporting = false
    @State private var exportedText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("My Card")
                .font(Theme.Text.title)
                .padding(Theme.Spacing.medium)

            Divider()

            if let card = myCard {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                        HStack(spacing: Theme.Spacing.medium) {
                            PersonAvatar(name: card.displayTitle, colorName: card.colorName, size: 48)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(card.displayTitle).font(Theme.Text.title)
                                if let role = card.personProfile?.roleTitle {
                                    Text(role)
                                        .font(Theme.Text.rowSubtitle)
                                        .foregroundStyle(Theme.Colors.secondaryText)
                                }
                            }
                            Spacer()
                            Button("Open") { navigation.selectItem(card.id) }
                        }

                        ForEach(profiles) { profile in
                            ShareProfileCard(
                                profile: profile,
                                card: shareableCard(for: card),
                                isSelected: profileID == profile.id,
                                onSelect: { profileID = profile.id },
                                onExport: { export(profile, card: card) }
                            )
                        }

                        Label(
                            """
                            Private notes, recorded facts, relationship history, and internal tags \
                            are never included in an exported card, whichever profile is chosen.
                            """,
                            systemImage: "lock.shield"
                        )
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Theme.Spacing.medium)
                }
            } else {
                EmptyStateView(
                    symbolName: "person.crop.square",
                    headline: "No card chosen",
                    message: "Open your own person record and choose “Make this my card”.",
                    actionTitle: "Create my card",
                    action: createMyCard
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier(AccessibilityID.People.myCard)
        .fileExporter(
            isPresented: $isExporting,
            document: VCardDocument(text: exportedText),
            contentType: .vCard,
            defaultFilename: "My Card"
        ) { _ in }
    }

    private var myCard: Item? {
        guard let services else { return nil }
        return try? services.persons.myCard()
    }

    private var profiles: [ShareProfile] {
        services?.shareProfiles ?? ShareProfile.defaults()
    }

    private func shareableCard(for person: Item) -> ShareableCard {
        var card = ShareableCard()
        card[.fullName] = person.displayTitle
        card[.pronouns] = person.personProfile?.pronouns
        card[.pronunciation] = person.personProfile?.pronunciation
        card[.jobTitle] = person.personProfile?.roleTitle
        card[.organization] = person.personProfile?.organizationName

        let emails = person.personProfile?.emails ?? []
        card[.workEmail] = emails.first { $0.label.lowercased().contains("work") }?.value ?? emails.first?.value
        card[.personalEmail] = emails.first { $0.label.lowercased().contains("home") }?.value ?? emails.first?.value

        let phones = person.personProfile?.phones ?? []
        card[.mobilePhone] = phones.first { $0.label.lowercased().contains("mobile") }?.value ?? phones.first?.value
        card[.workPhone] = phones.first { $0.label.lowercased().contains("work") }?.value

        card[.website] = person.personProfile?.websites.first?.value
        card[.postalAddress] = person.personProfile?.addresses.first?.value

        if let birthday = person.personProfile?.birthdayDate(
            calendar: services?.dateProvider.calendar ?? .autoupdatingCurrent
        ), birthday.hasYear {
            card[.birthday] = birthday.displayText
        }

        return card
    }

    private func export(_ profile: ShareProfile, card person: Item) {
        exportedText = VCardEmitter.emit(card: shareableCard(for: person), profile: profile)
        isExporting = true
    }

    private func createMyCard() {
        guard let services else { return }
        services.perform {
            let person = try services.persons.createPerson(PersonDraft(fullName: "Me"))
            try services.persons.setMyCard(person)
            services.noteChange(to: person)
            navigation.selectItem(person.id)
        }
    }
}

struct ShareProfileCard: View {
    let profile: ShareProfile
    let card: ShareableCard
    let isSelected: Bool
    let onSelect: () -> Void
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Text(profile.name)
                    .font(Theme.Text.rowTitleEmphasised)
                Spacer()
                Button("Export vCard…", action: onExport)
                    .controlSize(.small)
            }

            Text(includedFields)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if profile.includesSensitiveFields {
                Label(
                    "Includes \(profile.sensitiveFieldNames.joined(separator: ", ").lowercased()).",
                    systemImage: "exclamationmark.triangle"
                )
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.warning)
            }

            DisclosureGroup("Preview") {
                Text(VCardEmitter.emit(card: card, profile: profile))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.small)
                    .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            }
            .font(Theme.Text.metadata)
        }
        .padding(Theme.Spacing.medium)
        .background(Theme.Colors.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(profile.name) sharing profile. \(includedFields)")
    }

    private var includedFields: String {
        profile.fields
            .map(\.displayName)
            .sorted()
            .joined(separator: ", ")
    }
}

/// A vCard on its way to a save panel.
struct VCardDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.vCard] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - Card scanning

/// Importing a business card, with a review step before anything is created.
///
/// ### Why the original is kept
/// The scan is a guess, and the review screen is where somebody checks it. Keeping the image as an
/// attachment means the check can be made again later — when the phone number turns out to be wrong,
/// the card is still there to read.
struct CardScanView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let navigation: NavigationModel

    @State private var isImporting = false
    @State private var scanned: ScannedCard?
    @State private var imageData: Data?

    /// The file the user picked, kept so the original can be copied in as provenance at save
    /// time rather than held in memory as bytes. `AttachmentStore` copies from a URL — which is
    /// also what keeps a large PDF off the heap while somebody reads the review form.
    @State private var sourceURL: URL?
    @State private var isRecognising = false
    @State private var failure: String?

    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var organization = ""
    @State private var jobTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Import a card")
                .font(Theme.Text.title)

            if scanned == nil {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Text("""
                        Choose a photo or PDF of a business card. Text is read on this Mac — nothing \
                        is uploaded, and Elephruit has no network access at all.
                        """)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Choose a file…") { isImporting = true }
                        .buttonStyle(.borderedProminent)

                    Text("""
                        Continuity Camera also works: right-click here and choose Import from \
                        iPhone. macOS runs the camera, so Elephruit never asks for camera access.
                        """)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                reviewForm
            }

            if isRecognising {
                ProgressView("Reading the card…")
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.warning)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create person") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 520)
        .accessibilityIdentifier(AccessibilityID.People.cardScan)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.image, .pdf],
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
    }

    private var reviewForm: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Label("Check this before it is saved", systemImage: "eye")
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(Theme.Colors.secondaryText)

            Form {
                TextField("Name", text: $name)
                TextField("Email", text: $email)
                TextField("Phone", text: $phone)
                TextField("Organization", text: $organization)
                TextField("Role", text: $jobTitle)
            }
            .formStyle(.grouped)

            if let scanned, !scanned.lines.isEmpty {
                DisclosureGroup("Everything read from the card (\(scanned.lines.count) lines)") {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(scanned.lines.enumerated()), id: \.offset) { _, line in
                            Text(line.text)
                                .font(Theme.Text.metadata)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Theme.Text.metadata)
            }

            Label("The original image is kept with the person, so this can be checked again later.", systemImage: "paperclip")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
    }

    private func handleImport(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            failure = "That file could not be read."
            return
        }

        imageData = data
        sourceURL = url
        isRecognising = true

        Task {
            defer { isRecognising = false }

            guard let recognizer = services?.textRecognizer else { return }
            do {
                let lines = try await recognizer.recognizeText(in: data)
                let card = BusinessCardInterpreter.interpret(lines)
                scanned = card
                prefill(from: card)

                if card.isEmpty {
                    failure = "No contact details were recognized. You can still fill them in yourself."
                }
            } catch {
                failure = "The card could not be read: \(error.localizedDescription)"
                scanned = ScannedCard(lines: [])
            }
        }
    }

    private func prefill(from card: ScannedCard) {
        name = card.bestName ?? ""
        email = card.emails.first ?? ""
        phone = card.phones.first ?? ""
        organization = card.organizationCandidates.first ?? ""
        jobTitle = card.jobTitleCandidates.first ?? ""
    }

    private func create() {
        guard let services else { return }

        services.perform {
            var draft = PersonDraft(
                fullName: name.trimmingCharacters(in: .whitespaces),
                roleTitle: jobTitle.isEmpty ? nil : jobTitle,
                organizationName: organization.isEmpty ? nil : organization,
                source: ItemSource(kind: .otherImport, identifier: "business-card")
            )
            if !email.isEmpty { draft.emails = [LabelledValue(label: "work", value: email)] }
            if !phone.isEmpty { draft.phones = [LabelledValue(label: "work", value: phone)] }

            let person = try services.persons.createPerson(draft)

            // The scan itself, kept as provenance. A guess that can be re-checked is worth far
            // more than one that cannot. The security scope is re-acquired here and balanced by the
            // `defer`, because the one taken during the import has long since been released.
            if let sourceURL {
                let didStart = sourceURL.startAccessingSecurityScopedResource()
                defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }
                _ = try services.attachments.attachCopy(of: sourceURL, to: person)
            }

            services.noteChange(to: person)
            navigation.select(.kind(.person))
            navigation.selectItem(person.id)
        }
        dismiss()
    }
}

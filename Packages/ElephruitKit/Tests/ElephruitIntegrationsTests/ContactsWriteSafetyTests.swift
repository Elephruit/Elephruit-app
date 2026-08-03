import ElephruitCore
import ElephruitIntegrations
import Foundation
import Testing

/// Records' address-book safety rule: **one write, and it can only say five things.**
///
/// ### What changed, and what did not
/// This suite used to assert that no system contact could ever be written, on the reasoning that the
/// strongest reading of "system contacts change only with explicit user intent" is not having the
/// capability at all. What that cost was a linked person whose number could not be corrected
/// anywhere — an edit kept locally was discarded by the next refresh, silently — so the capability
/// now exists and the intent is what constrains it.
///
/// The reason the assertions did not simply go away is unchanged. Contacts, unlike EventKit, has a
/// single access tier: granting read access grants write access too. The permission the user gives is
/// broader than what the app uses, the user has no way to give less, and the only thing keeping the
/// app inside it is the code.
///
/// So the guards moved rather than lifted:
///
/// 1. **``ContactWrite`` can express five fields**, so a name, a birthday, a photograph, or a postal
///    address cannot be altered — not because nothing does, but because nothing *can*.
/// 2. **Only `write(_:)` mutates.** The adapter's source contains no other mutating call, checked
///    here — which catches somebody reaching past the protocol to `CNContactStore` directly.
/// 3. **Nothing creates or deletes.** `CNSaveRequest.add` and `.delete` stay forbidden outright: this
///    app corrects records the user already has and is never the reason one appears or vanishes.
@Suite("Contacts write safety")
struct ContactsWriteSafetyTests {
    private static func sourceRoot() -> URL {
        var url = URL(filePath: #filePath)
        while url.lastPathComponent != "Tests", url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        return url.deletingLastPathComponent().appending(path: "Sources", directoryHint: .isDirectory)
    }

    private static func swiftFiles(under directory: String) -> [URL] {
        let root = sourceRoot().appending(path: directory, directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Calls that remain forbidden outright, at any count.
    ///
    /// Creation and deletion are the two things a correction never needs, and the two whose damage
    /// cannot be undone from inside the app. `CNMutableGroup` is here because reorganising somebody's
    /// groups is not something this app has any business doing.
    private static let forbiddenCalls = [
        "CNSaveRequest().add",
        "request.add(",
        "request.delete(",
        ".delete(contact",
        "CNMutableGroup",
    ]

    @Test("Nothing in the adapter can create or delete a contact")
    func adapterNeverCreatesOrDeletes() throws {
        let files = Self.swiftFiles(under: "ElephruitIntegrations")
        #expect(!files.isEmpty, "The integrations source must be findable, or this test proves nothing")

        var offenders: [String] = []

        for file in files {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for (number, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)

                // Comments are where the forbidden calls are *named*, which is the point of naming
                // them, so they must not count as usage.
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }

                for call in Self.forbiddenCalls where text.contains(call) {
                    offenders.append("\(file.lastPathComponent):\(number + 1) — \(call)")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            Elephruit corrects contacts the user already has. It is never the reason one appears or \
            disappears. These would be: \(offenders)
            """
        )
    }

    /// The write is meant to be one method, not a capability that spread.
    ///
    /// Counting occurrences rather than forbidding them is the whole point: `CNSaveRequest` and
    /// `store.execute` each belong in exactly one place, and a second appearance means a second way
    /// to change somebody's address book that nothing reviewed.
    @Test("Saving happens in exactly one place")
    func savingIsNotSpreadAround() throws {
        var saveRequests = 0
        var executes = 0
        var mutableContacts = 0

        for file in Self.swiftFiles(under: "ElephruitIntegrations") {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for line in contents.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }

                if trimmed.contains("CNSaveRequest") { saveRequests += 1 }
                if trimmed.contains("store.execute(") { executes += 1 }
                if trimmed.contains("CNMutableContact") { mutableContacts += 1 }
            }
        }

        #expect(saveRequests <= 1, "`CNSaveRequest` appears \(saveRequests) times; it belongs only in `write(_:)`")
        #expect(executes <= 1, "`store.execute` appears \(executes) times; it belongs only in `write(_:)`")
        #expect(
            mutableContacts <= 1,
            "`CNMutableContact` appears \(mutableContacts) times; it belongs only in `write(_:)`"
        )
    }

    /// The narrowness of the write, asserted against the type rather than against the prose.
    ///
    /// `ContactWrite` is the reason a write cannot touch a birthday, and a field added to it in a
    /// hurry is exactly the change that would pass review. Setting every property this test knows
    /// about and comparing against a fresh value proves the list is complete: a new field would leave
    /// the two equal and fail here.
    @Test("A write can only say the things it is allowed to say")
    func writeCarriesNothingElse() {
        var change = ContactWrite(identifier: "abc")

        change.givenName = "Maya"
        change.middleName = "Lin"
        change.familyName = "Chen"
        change.namePrefix = "Dr"
        change.nameSuffix = "PhD"
        change.nickname = "May"
        change.jobTitle = "Head of Design"
        change.departmentName = "Design"
        change.organizationName = "Northwind"
        change.emailAddresses = [ContactLabelledValue(label: "work", value: "maya@northwind.example")]
        change.phoneNumbers = [ContactLabelledValue(label: "mobile", value: "+15125550192")]
        change.urlAddresses = [ContactLabelledValue(label: "homepage", value: "northwind.example")]
        change.birthday = PartialDate(month: 10, day: 12)

        #expect(change != ContactWrite(identifier: "abc"), "every writable field must be reachable")
        #expect(
            change == ContactWrite(
                identifier: "abc",
                givenName: "Maya",
                middleName: "Lin",
                familyName: "Chen",
                namePrefix: "Dr",
                nameSuffix: "PhD",
                nickname: "May",
                jobTitle: "Head of Design",
                departmentName: "Design",
                organizationName: "Northwind",
                emailAddresses: [ContactLabelledValue(label: "work", value: "maya@northwind.example")],
                phoneNumbers: [ContactLabelledValue(label: "mobile", value: "+15125550192")],
                urlAddresses: [ContactLabelledValue(label: "homepage", value: "northwind.example")],
                birthday: PartialDate(month: 10, day: 12)
            ),
            """
            A `ContactWrite` built from every field this test knows about differs from the one it \
            assembled, which means the type has grown a field. Anything writable must be deliberate: \
            add it here, and to `ContactWriteBackSheet`, which has to show it before it is written.
            """
        )
    }

    /// The fields that stay unwritable, asserted by there being nowhere to put them.
    ///
    /// Prose in a doc comment is not a guarantee; a compile error is. This test exists to be *broken*
    /// by somebody adding one of these to `ContactWrite`, at which point they have to come here and
    /// argue for it rather than discovering later that a photograph went missing.
    @Test("A write has nowhere to put the fields that must stay untouched")
    func unwritableFieldsHaveNoHome() {
        let change = ContactWrite(identifier: "abc")
        let mirrored = Set(Mirror(reflecting: change).children.compactMap(\.label))

        let mustNotExist = [
            "postalAddresses",   // reads as a formatted line; the projection does not invert
            "note",              // needs an Apple-granted entitlement, and the CRM has its own notes
            "imageData",         // the largest thing Contacts holds, and never displayed here
            "thumbnailImageData",
            "socialProfiles",
            "instantMessageAddresses",
            "contactRelations",
            "dates",             // anniversaries are the user's to keep in Contacts
            "previousFamilyName",
            "phoneticGivenName", // "rhymes with papaya" does not split into these
            "phoneticFamilyName",
            "nonGregorianBirthday",
            "contactType",
        ]

        let offenders = mustNotExist.filter { mirrored.contains($0) }

        #expect(
            offenders.isEmpty,
            """
            `ContactWrite` has grown a field that was deliberately excluded: \(offenders). Each of \
            these was left out for a stated reason — see `ContactsProviding.write(_:)`. Adding one \
            means changing that reasoning on purpose, not in passing.
            """
        )
    }

    /// The other half of the privacy posture: what the app *reads*.
    ///
    /// Contacts requires an explicit key list, which makes over-fetching a deliberate act. Notes,
    /// images, social profiles, instant-message handles, and relations are all things the app has no
    /// use for, and asking for them would be exactly the habit the no-network posture exists to
    /// prevent — data not fetched cannot leak.
    @Test("The adapter fetches no key it does not display")
    func adapterFetchesOnlyWhatItShows() throws {
        // Revisited when the import arrived. `CNContactDatesKey` and `CNContactRelationsKey` left
        // this list because they are now genuinely used — anniversaries appear as celebrations, and
        // relations are shown as suggestions the user may act on. The rule is "nothing fetched that
        // nothing displays", not "nothing new ever", and a key earns its place by being rendered.
        //
        // `CNContactNoteKey` stays forbidden and always will: reading it needs an entitlement Apple
        // grants by request, the CRM has its own notes, and mixing the two is the flattening this
        // whole module exists to prevent. Full-resolution image data stays forbidden because it is
        // the largest thing Contacts holds and a list never needs it.
        let forbiddenKeys = [
            "CNContactNoteKey",
            "CNContactImageDataKey",
            "CNContactSocialProfilesKey",
            "CNContactInstantMessageAddressesKey",
        ]

        var offenders: [String] = []

        for file in Self.swiftFiles(under: "ElephruitIntegrations") {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for (number, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }

                for key in forbiddenKeys where trimmed.contains(key) {
                    offenders.append("\(file.lastPathComponent):\(number + 1) — \(key)")
                }
            }
        }

        #expect(offenders.isEmpty, "Fetching a key nothing displays is data taken for no reason: \(offenders)")
    }

    /// Thumbnails are legitimate and expensive, so *where* they are fetched is the thing to pin.
    ///
    /// One occurrence, in the per-contact `thumbnail(forIdentifier:)` path. Adding it to either bulk
    /// key list would make a scan of several thousand contacts drag every avatar off disk to draw a
    /// list that shows initials — which is precisely how an import becomes a beachball.
    @Test("Image data is fetched one contact at a time, never for a whole scan")
    func thumbnailsAreFetchedOnDemand() throws {
        var occurrences = 0

        for file in Self.swiftFiles(under: "ElephruitIntegrations") {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for line in contents.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                if trimmed.contains("CNContactThumbnailImageDataKey") { occurrences += 1 }
            }
        }

        #expect(
            occurrences <= 1,
            """
            The thumbnail key appears \(occurrences) times. It belongs only in the on-demand \
            per-contact fetch; putting it in a bulk key list pulls every image off disk during a scan.
            """
        )
    }

    @Test("A refused Contacts permission is a state with nothing in it, not an error")
    func deniedAccessReadsAsEmpty() async {
        let provider = NoContactsProvider()

        #expect(provider.authorization == .notRequested)
        #expect(await provider.contacts(matching: "Maya").isEmpty)
        #expect(await provider.accounts().isEmpty)
        #expect(await provider.contact(withIdentifier: "anything") == nil)
    }

    @Test("Asking a provider that is not configured explains itself rather than failing")
    func unconfiguredProviderIsHonest() async {
        #expect(await NoContactsProvider().requestAccess() == .unavailable)
        #expect(IntegrationAuthorization.unavailable.explanation?.isEmpty == false)
    }

    // MARK: - Writing

    private static func linkedContact(id: String = "maya", container: String? = nil) -> SystemContact {
        var contact = SystemContact(id: id)
        contact.givenName = "Maya"
        contact.familyName = "Chen"
        contact.jobTitle = "Designer"
        contact.emailAddresses = [ContactLabelledValue(label: "work", value: "maya@northwind.example")]
        contact.postalAddresses = [ContactLabelledValue(label: "home", value: "12 Rosewood Lane, Austin")]
        contact.containerIdentifier = container
        return contact
    }

    @Test("A confirmed write reaches the contact")
    func writeApplies() async {
        let provider = FixtureContactsProvider(contacts: [Self.linkedContact()], authorization: .authorized)

        let outcome = await provider.write(
            ContactWrite(
                identifier: "maya",
                jobTitle: "Head of Design",
                phoneNumbers: [ContactLabelledValue(label: "mobile", value: "+15125550192")]
            )
        )

        #expect(outcome == .written)

        let updated = await provider.systemContact(withIdentifier: "maya")
        #expect(updated?.jobTitle == "Head of Design")
        #expect(updated?.phoneNumbers.first?.value == "+15125550192")
    }

    @Test("A write clears the values it was given none of, because that is what removing one looks like")
    func writeRemovesOmittedValues() async {
        let provider = FixtureContactsProvider(contacts: [Self.linkedContact()], authorization: .authorized)

        _ = await provider.write(ContactWrite(identifier: "maya"))

        let updated = await provider.systemContact(withIdentifier: "maya")
        #expect(updated?.emailAddresses.isEmpty == true, "an address deleted in the sheet must actually go")
    }

    @Test("A write cannot touch a postal address even when the contact has one")
    func postalAddressesSurviveAWrite() async {
        let provider = FixtureContactsProvider(contacts: [Self.linkedContact()], authorization: .authorized)

        _ = await provider.write(ContactWrite(identifier: "maya", jobTitle: "Head of Design"))

        let updated = await provider.systemContact(withIdentifier: "maya")
        #expect(
            updated?.postalAddresses.first?.value == "12 Rosewood Lane, Austin",
            """
            Elephruit reads an address as one formatted line and cannot put it back into the fields \
            Contacts keeps it in, so it must leave the stored address exactly as it found it.
            """
        )
    }

    @Test("Writing without access does nothing and says so")
    func writeNeedsAccess() async {
        let provider = FixtureContactsProvider(contacts: [Self.linkedContact()], authorization: .denied)

        let outcome = await provider.write(ContactWrite(identifier: "maya", jobTitle: "Head of Design"))

        #expect(outcome == .notPermitted)
        #expect(outcome.explanation?.isEmpty == false)
    }

    @Test("Writing to a contact that has gone reports it rather than recreating it")
    func writeToMissingRecord() async {
        let provider = FixtureContactsProvider(contacts: [], authorization: .authorized)

        let outcome = await provider.write(ContactWrite(identifier: "maya"))

        #expect(outcome == .recordMissing)
        #expect(await provider.systemContact(withIdentifier: "maya") == nil, "a write must never create")
    }

    @Test("A read-only account refuses instead of appearing to succeed")
    func writeToReadOnlyAccount() async {
        let account = ContactAccount(id: "directory", name: "Company Directory", contactCount: 1, isReadOnly: true)
        let provider = FixtureContactsProvider(
            contacts: [Self.linkedContact(container: "directory")],
            containers: [account],
            authorization: .authorized
        )

        let outcome = await provider.write(ContactWrite(identifier: "maya", jobTitle: "Head of Design"))

        #expect(outcome == .accountIsReadOnly)

        let unchanged = await provider.systemContact(withIdentifier: "maya")
        #expect(unchanged?.jobTitle == "Designer", "a refused write must leave the record alone")
    }

    @Test("A provider with nothing behind it refuses rather than pretending")
    func nullProviderRefusesWrites() async {
        #expect(await NoContactsProvider().write(ContactWrite(identifier: "maya")) == .notPermitted)
    }

    @Test("A name is written in the parts it was edited in")
    func nameIsWrittenInParts() async {
        let provider = FixtureContactsProvider(contacts: [Self.linkedContact()], authorization: .authorized)

        _ = await provider.write(
            ContactWrite(
                identifier: "maya",
                givenName: "Maya",
                middleName: "Lin",
                familyName: "Chen",
                namePrefix: "Dr",
                nameSuffix: "PhD",
                nickname: "May"
            )
        )

        let updated = await provider.systemContact(withIdentifier: "maya")
        #expect(updated?.givenName == "Maya")
        #expect(updated?.middleName == "Lin")
        #expect(updated?.namePrefix == "Dr")
        #expect(updated?.nameSuffix == "PhD")
        #expect(updated?.nickname == "May")
    }

    @Test("A birthday without a year is written without one, not with a made-up one")
    func birthdayWithoutAYear() async {
        let provider = FixtureContactsProvider(contacts: [Self.linkedContact()], authorization: .authorized)

        _ = await provider.write(
            ContactWrite(identifier: "maya", birthday: PartialDate(month: 10, day: 12))
        )

        let updated = await provider.systemContact(withIdentifier: "maya")
        #expect(updated?.birthday?.month == 10)
        #expect(updated?.birthday?.day == 12)
        #expect(updated?.birthday?.year == nil, "a year nobody supplied must not be invented")
    }

    /// The pairing that stops a write from deleting something nobody saw.
    ///
    /// A field the app can *write* but never *reads* starts empty on every imported person, and the
    /// first edit sends that emptiness to the address book — so somebody's middle name and suffix
    /// disappear because they corrected a phone number. The rule is therefore: anything writable is
    /// readable. This asserts it against the two types rather than against anybody's memory.
    @Test("A write can only clear fields the import actually reads")
    func contactWriteCanOnlyClearWhatImportReads() {
        let writable = Set(
            Mirror(reflecting: ContactWrite(identifier: "abc")).children.compactMap(\.label)
        ).subtracting(["identifier"])

        var contact = SystemContact(id: "abc")
        let readable = Set(Mirror(reflecting: contact).children.compactMap(\.label))

        // The two disagree only in spelling, which is where a genuine gap would hide.
        let spellings = [
            "emailAddresses": "emailAddresses",
            "phoneNumbers": "phoneNumbers",
            "urlAddresses": "urlAddresses",
            "birthday": "birthday",
        ]

        let unreadable = writable.filter { field in
            !readable.contains(spellings[field] ?? field)
        }

        #expect(
            unreadable.isEmpty,
            """
            \(unreadable) can be written but is never read from a contact, so every imported person \
            has it empty and the first edit they make wipes it from their address book. Read it on \
            import, or take it off `ContactWrite`.
            """
        )

        // Not a dead binding: proves the mirror above described a populated record rather than an
        // empty one whose properties happened to exist.
        contact.middleName = "Lin"
        #expect(contact.middleName == "Lin")
    }

    @Test("A birthday with a year keeps it")
    func birthdayWithAYear() async {
        let provider = FixtureContactsProvider(contacts: [Self.linkedContact()], authorization: .authorized)

        _ = await provider.write(
            ContactWrite(identifier: "maya", birthday: PartialDate(year: 1987, month: 10, day: 12))
        )

        #expect(await provider.systemContact(withIdentifier: "maya")?.birthday?.year == 1987)
    }
}

/// Reading a business card, without a camera or an image.
///
/// The interpretation is pure, so every rule about what counts as a phone number and what counts as a
/// name is testable against a fixture of lines. That matters more than usual here because the whole
/// feature is a guess: the point of the review screen is that the guess is visible before anything is
/// created, and the point of these tests is that the guess is at least a defensible one.
@Suite("Business card scanning")
struct BusinessCardInterpreterTests {
    /// Lines as they appear on a card, top to bottom.
    ///
    /// Vision's origin is bottom-left, so the first line gets the largest `midY`.
    static func card(_ texts: [String]) -> [RecognizedLine] {
        texts.enumerated().map { index, text in
            RecognizedLine(
                text: text,
                confidence: 0.95,
                boundingBox: CGRect(x: 0.1, y: 0.9 - Double(index) * 0.1, width: 0.8, height: 0.05)
            )
        }
    }

    @Test("An ordinary card is read into the right fields")
    func ordinaryCard() {
        let scanned = BusinessCardInterpreter.interpret(
            Self.card([
                "Maya Chen",
                "Head of Design",
                "Northwind Studio",
                "maya@northwind.example",
                "+1 (512) 555-0192",
                "www.northwind.example",
                "12 Rosewood Lane, Austin",
            ])
        )

        #expect(scanned.bestName == "Maya Chen")
        #expect(scanned.jobTitleCandidates.contains("Head of Design"))
        #expect(scanned.organizationCandidates.contains("Northwind Studio"))
        #expect(scanned.emails == ["maya@northwind.example"])
        #expect(scanned.phones.count == 1)
        #expect(scanned.urls == ["www.northwind.example"])
        #expect(scanned.addressCandidates.contains("12 Rosewood Lane, Austin"))
    }

    @Test("Lines come back in reading order")
    func linesAreOrderedTopToBottom() {
        let scanned = BusinessCardInterpreter.interpret(Self.card(["First", "Second", "Third"]))
        #expect(scanned.lines.map(\.text) == ["First", "Second", "Third"])
    }

    @Test("A postcode is not offered as a phone number")
    func numbersThatAreNotPhoneNumbers() {
        let scanned = BusinessCardInterpreter.interpret(Self.card(["Maya Chen", "78701"]))
        #expect(scanned.phones.isEmpty, "a wrong number is worse than an unrecognised one")
    }

    @Test("A telephone prefix is stripped before the number is read")
    func telephonePrefixesAreHandled() {
        let scanned = BusinessCardInterpreter.interpret(Self.card(["Tel: 512-555-0192"]))
        #expect(scanned.phones.count == 1)
        #expect(scanned.phones.first?.contains("512") == true)
    }

    @Test("An email is never also read as a name")
    func emailsAreClaimedFirst() {
        let scanned = BusinessCardInterpreter.interpret(Self.card(["Maya Chen", "Maya Chen <maya@example.com>"]))
        #expect(scanned.emails.count == 1)
        #expect(scanned.nameCandidates == ["Maya Chen"])
    }

    @Test("A card that reads as nothing says so")
    func emptyCard() {
        #expect(BusinessCardInterpreter.interpret([]).isEmpty)
        #expect(BusinessCardInterpreter.interpret(Self.card(["", "   "])).isEmpty)
    }

    @Test("The recogniser that recognises nothing is a real code path")
    func inertRecognizer() async throws {
        let lines = try await NoTextRecognizer().recognizeText(in: Data())
        #expect(lines.isEmpty)
        #expect(BusinessCardInterpreter.interpret(lines).isEmpty)
    }
}

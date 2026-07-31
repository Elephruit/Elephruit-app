import ElephruitCore
import ElephruitIntegrations
import Foundation
import Testing

/// The People module's equivalent of the calendar's promise: **no system contact is ever written.**
///
/// ### Why this needs asserting rather than reviewing
/// The requirement is that system contacts change "only with explicit user intent". The strongest
/// available reading of that is not a confirmation dialog — it is not having the capability at all,
/// and a user who wants Elephruit's profile in their address book exporting a vCard through a save
/// panel they opened themselves.
///
/// Contacts, unlike EventKit, has a single access tier: granting read access grants write access
/// too. So the permission the user gives is broader than what the app uses, the user has no way to
/// give less, and the only thing making "read-only" true is the code.
///
/// Two independent guards, because either alone can be defeated:
///
/// 1. **`ContactsProviding` has no write method**, so calling one is a compile error rather than a
///    policy somebody remembers.
/// 2. **The Contacts adapter's source contains no mutating call**, checked here — which catches the
///    case where someone reaches past the protocol to `CNContactStore` directly.
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

    /// Every Contacts call that changes something.
    ///
    /// Named individually rather than matched by pattern, on the same terms as the calendar list: a
    /// roster of exact symbols says what is forbidden, and anybody adding one has to add it here too.
    private static let mutatingCalls = [
        "CNSaveRequest",
        "store.execute(",
        ".add(contact",
        ".update(contact",
        ".delete(contact",
        "CNMutableContact",
        "CNMutableGroup",
    ]

    @Test("The Contacts adapter contains no call that could change a contact")
    func adapterNeverWrites() throws {
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

                for call in Self.mutatingCalls where text.contains(call) {
                    offenders.append("\(file.lastPathComponent):\(number + 1) — \(call)")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            Elephruit holds full Contacts access because Contacts offers nothing narrower, and never \
            writes. These would: \(offenders)
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
        let forbiddenKeys = [
            "CNContactNoteKey",
            "CNContactImageDataKey",
            "CNContactThumbnailImageDataKey",
            "CNContactSocialProfilesKey",
            "CNContactInstantMessageAddressesKey",
            "CNContactRelationsKey",
            "CNContactDatesKey",
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

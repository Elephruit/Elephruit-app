import ElephruitCore
import ElephruitDesign
@testable import ElephruitFeaturesCore
import ElephruitIntegrations
import Foundation
import Testing

/// The letters in the circle when there is no photograph.
///
/// One derivation, exercised here rather than in four view files — see ``ElephruitDesign/Avatar``
/// for the two rules this replaced.
@Suite("Avatar monograms")
@MainActor
struct AvatarMonogramTests {
    @Test("First word and last word, not the first two")
    func firstAndLast() {
        #expect(Avatar.initials(from: "Amara Okonjo") == "AO")
        // The case the Mac's own avatar got wrong: four words, one surname.
        #expect(Avatar.initials(from: "Rosa María de la Cruz") == "RC")
        #expect(Avatar.initials(from: "Cher") == "C")
    }

    /// A monogram is made of letters, and a name that ends in a number does not have a numeric
    /// surname. The seeded library is full of these, and a column of "A1 A3 A6" read as serial
    /// numbers rather than as people.
    @Test("A trailing number is not an initial")
    func digitsAreNotInitials() {
        #expect(Avatar.initials(from: "Amara Abara 1") == "AA")
        #expect(Avatar.initials(from: "Viggo Xu 112") == "VX")
        #expect(Avatar.initials(from: "John Smith 2") == "JS")
    }

    /// Nothing alphabetic anywhere. An empty circle says less than the record's own first character.
    @Test("A name with no letters keeps its first character")
    func nothingAlphabetic() {
        #expect(Avatar.initials(from: "1975") == "1")
        #expect(Avatar.initials(from: "") == "")
        #expect(Avatar.initials(from: "   ") == "")
    }

    @Test("Extra spaces are not extra words")
    func spacingIsIgnored() {
        #expect(Avatar.initials(from: "  Maya   Chen  ") == "MC")
    }
}

/// Reading contact photographs, and the cache that makes reading them affordable.
///
/// ### Why the counting matters more than the bytes
/// The feature is one line of view code — draw a face if there is one. What is easy to get wrong is
/// *how often the address book is asked*, and that is invisible on screen: a list that re-fetches
/// every face on every flick looks exactly like one that does not, until it is scrolled on a phone
/// with two thousand contacts. So most of these tests count calls rather than compare images.
@Suite("Contact photographs")
@MainActor
struct ContactPhotoTests {
    /// A provider that answers with a fixed picture and keeps score.
    ///
    /// A class with a counter rather than `FixtureContactsProvider`, because what is under test is
    /// the number of reads, and the fixture is deliberately silent about how many it has served.
    class CountingProvider: ContactsProviding, @unchecked Sendable {
        let picture: Data?
        private(set) var reads = 0

        init(picture: Data? = Data([0x01, 0x02, 0x03])) {
            self.picture = picture
        }

        var authorization: IntegrationAuthorization { .authorized }
        var changes: AsyncStream<Void> { AsyncStream { $0.finish() } }
        func requestAccess() async -> IntegrationAuthorization { .authorized }
        func accounts() async -> [ContactAccount] { [] }
        func contacts(matching query: String) async -> [ContactSummary] { [] }
        func contact(withIdentifier identifier: String) async -> ContactSummary? { nil }
        func systemContact(withIdentifier identifier: String) async -> SystemContact? { nil }
        func systemContact(matching signature: ContactIdentitySignature) async -> SystemContact? { nil }
        func create(_ contact: ContactCreate) async -> ContactCreateOutcome { .notPermitted }
        func write(_ change: ContactWrite) async -> ContactWriteOutcome { .notPermitted }
        func currentHistoryToken() async -> Data? { nil }
        func changes(since token: Data) async -> ContactChangeSet? { nil }

        func enumerateContacts(
            inContainers containers: [String],
            onBatch: @Sendable ([SystemContact]) async -> Void
        ) async -> Int { 0 }

        func thumbnail(forIdentifier identifier: String) async -> Data? {
            reads += 1
            return picture
        }
    }

    /// A provider that stops inside `thumbnail` until the test lets it go, and announces that it
    /// has stopped. Everything else is a `CountingProvider` that never answers.
    final class GatedProvider: CountingProvider, @unchecked Sendable {
        private let arrivals = AsyncStream<Void>.makeStream()
        private var waiting: CheckedContinuation<Void, Never>?

        /// Yields once each time a fetch has begun and suspended.
        var entries: AsyncStream<Void> { arrivals.stream }

        override func thumbnail(forIdentifier identifier: String) async -> Data? {
            await withCheckedContinuation { continuation in
                waiting = continuation
                arrivals.continuation.yield()
            }
            return picture
        }

        func release() {
            waiting?.resume()
            waiting = nil
        }
    }

    /// A scratch defaults suite, so enabling Contacts here leaves nothing behind.
    func makeService(_ provider: CountingProvider) -> ContactsService {
        let name = "contact-photos-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        return ContactsService(
            dateProvider: FixedDateProvider.reference,
            defaults: defaults,
            makeProvider: { provider }
        )
    }

    // MARK: - The cache

    @Test("A face is read from the address book once, however many rows ask for it")
    func oneReadPerContact() async {
        let provider = CountingProvider()
        let service = makeService(provider)
        await service.enable()

        for _ in 0..<5 {
            _ = await service.photo(forContactIdentifier: "abc")
        }

        #expect(provider.reads == 1)
        #expect(service.cachedPhoto(forContactIdentifier: "abc") == provider.picture)
    }

    /// The answer that costs the most to keep re-discovering, because it is the common one.
    @Test("Having no photograph is remembered, not re-asked")
    func absenceIsCachedToo() async {
        let provider = CountingProvider(picture: nil)
        let service = makeService(provider)
        await service.enable()

        #expect(await service.photo(forContactIdentifier: "abc") == nil)
        #expect(await service.photo(forContactIdentifier: "abc") == nil)

        #expect(provider.reads == 1)
        #expect(service.photos.state(for: "abc") == .absent)
    }

    /// Bytes that cannot be drawn are the same as no bytes, and must not be asked for again.
    @Test("Empty image data reads as no photograph")
    func emptyDataIsAbsence() async {
        let provider = CountingProvider(picture: Data())
        let service = makeService(provider)
        await service.enable()

        #expect(await service.photo(forContactIdentifier: "abc") == nil)
        #expect(service.photos.state(for: "abc") == .absent)
    }

    @Test("Rows that ask at the same moment join one read")
    func concurrentCallersShareOneRead() async {
        let provider = CountingProvider()
        let service = makeService(provider)
        await service.enable()

        async let first = service.photo(forContactIdentifier: "abc")
        async let second = service.photo(forContactIdentifier: "abc")
        async let third = service.photo(forContactIdentifier: "abc")

        let answers = await [first, second, third]

        #expect(answers.allSatisfy { $0 == provider.picture })
        #expect(provider.reads == 1)
    }

    /// The unread cache is what makes a row draw its face in the first frame rather than fading it
    /// in again every time the row is recycled.
    @Test("Nothing is known before anybody asks")
    func cachedIsEmptyUntilFetched() async {
        let provider = CountingProvider()
        let service = makeService(provider)
        await service.enable()

        #expect(service.cachedPhoto(forContactIdentifier: "abc") == nil)
        #expect(provider.reads == 0)

        _ = await service.photo(forContactIdentifier: "abc")

        #expect(service.cachedPhoto(forContactIdentifier: "abc") == provider.picture)
    }

    // MARK: - Bounds

    /// An address book is unbounded, so an unbounded cache is a leak with a friendly name.
    @Test("The oldest faces are dropped once the cache is full")
    func theCacheIsBounded() async {
        let store = ContactPhotoStore(limit: 3)

        for index in 0..<5 {
            _ = await store.photo(for: "id-\(index)") { Data([UInt8(index)]) }
        }

        #expect(store.cached("id-0") == nil)
        #expect(store.cached("id-1") == nil)
        #expect(store.cached("id-2") == Data([2]))
        #expect(store.cached("id-4") == Data([4]))
    }

    // MARK: - Switching the address book off

    @Test("Turning Contacts off forgets every face it read")
    func disablingForgets() async {
        let provider = CountingProvider()
        let service = makeService(provider)
        await service.enable()
        _ = await service.photo(forContactIdentifier: "abc")
        #expect(service.cachedPhoto(forContactIdentifier: "abc") != nil)

        service.disable()

        #expect(service.cachedPhoto(forContactIdentifier: "abc") == nil)
        #expect(service.photos.state(for: "abc") == nil)
    }

    /// The window this closes: a read already in flight, answering after the switch was thrown.
    ///
    /// Deterministic rather than timed. The provider suspends inside `thumbnail` and says so, which
    /// is what lets the test disable the integration at exactly the moment a fetch is outstanding —
    /// the state a `sleep` would only sometimes produce.
    @Test("A read still in flight when Contacts is switched off does not put its face back")
    func disablingBeatsAnOutstandingRead() async {
        let provider = GatedProvider()
        let service = makeService(provider)
        await service.enable()

        let pending = Task { await service.photo(forContactIdentifier: "abc") }

        var entries = provider.entries.makeAsyncIterator()
        _ = await entries.next()

        service.disable()
        provider.release()
        _ = await pending.value

        #expect(service.cachedPhoto(forContactIdentifier: "abc") == nil)
        #expect(service.photos.state(for: "abc") == nil, "a forgotten face must stay forgotten")
    }

    /// The integration starts off, and off means the address book is not touched at all.
    @Test("A disabled integration answers without asking anybody")
    func disabledNeverReads() async {
        let provider = CountingProvider()
        let service = makeService(provider)

        #expect(await service.photo(forContactIdentifier: "abc") == nil)
        #expect(service.cachedPhoto(forContactIdentifier: "abc") == nil)
        #expect(provider.reads == 0)
    }

    @Test("A person with no linked contact is not a lookup")
    func noIdentifierIsNoRead() async {
        let provider = CountingProvider()
        let service = makeService(provider)
        await service.enable()

        #expect(await service.photo(forContactIdentifier: nil) == nil)
        #expect(await service.photo(forContactIdentifier: "") == nil)
        #expect(provider.reads == 0)
    }

    // MARK: - The fixture library

    /// The fixture is the design-review library, and a review of a People list with no faces in it
    /// reviews the wrong screen.
    @Test("The fixture address book has some faces and mostly not")
    func fixtureLibraryIsMixed() async {
        let provider = FixtureContactsProvider(
            contacts: ContactFixtures.library,
            containers: ContactFixtures.containers,
            authorization: .authorized
        )

        #expect(await provider.thumbnail(forIdentifier: "fixture-tomas") != nil)
        #expect(await provider.thumbnail(forIdentifier: "fixture-maya") == nil)
        #expect(await provider.thumbnail(forIdentifier: "no-such-contact") == nil)
    }

    /// The sample CRM's Maya carries this identifier, which is what puts one face in the People list
    /// a design review photographs. See `PeopleSampleData`.
    @Test("The sample library's linked person has a face")
    func sampleLinkedPersonHasAPicture() async {
        let provider = FixtureContactsProvider(
            contacts: ContactFixtures.library,
            containers: ContactFixtures.containers,
            authorization: .authorized
        )

        #expect(await provider.thumbnail(forIdentifier: "sample-contact-maya") != nil)
    }

    @Test("A fixture that has not been authorized shows nobody's face")
    func fixtureRespectsAuthorization() async {
        let provider = FixtureContactsProvider(
            contacts: ContactFixtures.library,
            containers: ContactFixtures.containers,
            authorization: .denied
        )

        #expect(await provider.thumbnail(forIdentifier: "fixture-tomas") == nil)
    }
}

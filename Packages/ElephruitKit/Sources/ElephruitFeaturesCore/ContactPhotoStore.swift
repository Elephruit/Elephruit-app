import Foundation

/// What is known about one person's photograph.
public enum ContactPhotoState: Sendable, Equatable {
    /// Asked and answered: this contact has no picture, or none this app can read.
    case absent
    /// The thumbnail bytes, as Contacts stores them.
    case photo(Data)

    public var data: Data? {
        if case .photo(let data) = self { return data }
        return nil
    }
}

/// The in-memory cache of contact thumbnails, and the thing that keeps a scroll off the disk.
///
/// ### Why a cache is the whole design
/// A photograph is fetched from Contacts by identifier, one contact at a time — see
/// `ContactsProviding.thumbnail(forIdentifier:)`, and `ContactsWriteSafetyTests` for why it is never
/// a bulk key. That is the right read and the wrong thing to do repeatedly: a `List` re-renders a
/// row whenever it comes back on screen, so a photograph fetched when a row appeared would be
/// fetched again on every flick, and a fast scroll through two thousand people would be two thousand
/// round trips to `CNContactStore` competing with the frames they are meant to fill.
///
/// So the read happens **once per identifier** and the answer is remembered — including the answer
/// *no*, which is the common one and the expensive one to keep re-discovering.
///
/// ### Why this is not `@Observable`
/// It was, and that was a mistake worth writing down. Observation tracks whole properties, not
/// dictionary keys, so a row that read the cache in its `body` took a dependency on *every* face in
/// it: one photograph arriving invalidated every visible row, and a screenful of people re-rendered
/// once per contact as the fetches landed.
///
/// A plain class inverts that. ``cached(_:)`` is an ordinary synchronous read that creates no
/// dependency at all and answers instantly for anything already known — which is what makes a
/// recycled row draw its face in the first frame instead of flickering through the monogram — and
/// the arrival of a *new* photograph is carried by one `@State` in the one row that asked for it.
///
/// ### Why it is bounded
/// A photograph is tens of kilobytes and an address book is unbounded, so an unbounded cache is a
/// leak with a friendly name — scrolling an imported library end to end would hold every face in it
/// forever. Least-recently-answered entries are dropped past ``limit``, which is set well above what
/// any screen shows at once: eviction should be something a long scroll eventually causes, never
/// something the rows currently visible can cause, because evicting a visible row's photograph would
/// re-fetch it immediately and the cache would thrash instead of cache.
///
/// ### Why nothing here is written down
/// Contacts owns contact photographs. This holds them for as long as they are being looked at and
/// forgets them when the integration is switched off — see ``forgetAll()``, which `ContactsService`
/// calls from `disable()`. A copy in the app's own store would be a second, staler address book, and
/// one that travels in an archive.
@MainActor
public final class ContactPhotoStore {
    /// How many answers are kept. Roughly a hundred screens of rows, and a few megabytes at most.
    public let limit: Int

    private var known: [String: ContactPhotoState] = [:]

    /// Identifiers in the order they were answered, so the oldest can be dropped.
    private var order: [String] = []

    /// Reads in flight, so two rows asking for the same person make one request.
    private var inFlight: [String: Task<Data?, Never>] = [:]

    public init(limit: Int = 300) {
        self.limit = limit
    }

    /// The answer already held, or `nil` for "no picture" and "nobody has asked yet" alike.
    ///
    /// The caller does not have to tell those two apart, because the fallback — a monogram — is the
    /// same and is already correct. Callers that need the distinction use ``state(for:)``.
    public func cached(_ identifier: String) -> Data? {
        known[identifier]?.data
    }

    /// What is known, distinguishing *asked and there is none* from *not asked*.
    public func state(for identifier: String) -> ContactPhotoState? {
        known[identifier]
    }

    /// The photograph, fetching it once if nobody has.
    ///
    /// Joins the existing read rather than starting a second one when a fetch for this identifier is
    /// already in flight — which is what makes it safe to call from every row that shows the person.
    public func photo(
        for identifier: String,
        fetch: @escaping @Sendable () async -> Data?
    ) async -> Data? {
        if let answered = known[identifier] { return answered.data }
        if let existing = inFlight[identifier] { return await existing.value }

        let task = Task { @MainActor [weak self] in
            let fetched = await fetch()
            self?.record(fetched, for: identifier)
            self?.inFlight.removeValue(forKey: identifier)
            // Empty bytes are a picture that cannot be drawn, which is the same as no picture at all
            // as far as anything downstream is concerned.
            return fetched?.isEmpty == false ? fetched : nil
        }
        inFlight[identifier] = task
        return await task.value
    }

    /// Forgets every face. Called when the address book is switched off.
    public func forgetAll() {
        known.removeAll()
        order.removeAll()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    /// Records an answer, and drops the oldest if the cache has outgrown its bound.
    private func record(_ data: Data?, for identifier: String) {
        known[identifier] = (data?.isEmpty == false ? data : nil).map(ContactPhotoState.photo) ?? .absent

        // Re-answered identifiers move to the back rather than appearing twice, so one entry in the
        // order is one entry in the cache and eviction never drops a key it has just re-recorded.
        order.removeAll { $0 == identifier }
        order.append(identifier)

        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            known.removeValue(forKey: oldest)
        }
    }
}

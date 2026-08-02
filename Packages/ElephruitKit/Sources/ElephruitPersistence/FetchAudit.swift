import ElephruitCore
import Foundation

/// Counts store access, so "this code path does not touch the database" can be *asserted* rather than
/// hoped for.
///
/// ### Why this exists
/// The sidebar previously performed two full-store materialisations on every body evaluation, and
/// nothing caught it — a timing test would have shown it as "a bit slow" on a fast machine and passed.
/// The primary acceptance criterion for the new sidebar is therefore behavioural: *zero item fetches
/// occur during rendering*. That is a statement about what the code does, not about how quickly it
/// does it, so it gives the same answer on any machine under any load.
///
/// ### Why it is not `#if DEBUG`
/// It compiles in every configuration and is simply `nil` in production, which costs one optional
/// check per fetch. Conditional compilation would mean the release build takes a different code path
/// from the one the tests exercise, and that difference is exactly where this class of bug hides.
///
/// Injected, never global — there is no `.shared`.
@MainActor
public final class FetchAudit {
    /// A count of each kind of store access since the last reset.
    public struct Tally: Sendable, Hashable {
        public var itemFetches = 0
        public var itemCountQueries = 0
        public var otherFetches = 0

        /// How many `Item` rows the store returned across those fetches.
        ///
        /// This is the materialisation count: a row costs its ~77 µs the moment the store returns
        /// it, whether or not a post-filter then discards it. A fetch *count* cannot see the
        /// difference — the old whole-store post-filters were also "one fetch" — so a test that
        /// wants to pin the shape of a query asserts on this. It still cannot see relationship
        /// faults fired later by Swift-side code; the scaling benchmarks remain the authoritative
        /// guard for total cost.
        public var itemRowsMaterialized = 0

        public var total: Int { itemFetches + itemCountQueries + otherFetches }

        /// A readable summary for a failing assertion.
        public var description: String {
            "\(itemFetches) item fetch(es) returning \(itemRowsMaterialized) row(s), "
                + "\(itemCountQueries) count quer(ies), \(otherFetches) other"
        }
    }

    public enum Access: Sendable {
        case itemFetch
        case itemCountQuery
        case other
    }

    public private(set) var tally = Tally()

    /// Set while a measurement is running, so ordinary application activity outside a measured block
    /// costs nothing but an optional check and a Boolean test.
    private var isRecording = false

    public init() {}

    /// Records one store access. `rows` is how many rows it returned, for the accesses that
    /// return any — see ``Tally/itemRowsMaterialized``.
    public func record(_ access: Access, rows: Int = 0) {
        guard isRecording else { return }

        switch access {
        case .itemFetch:
            tally.itemFetches += 1
            tally.itemRowsMaterialized += rows
        case .itemCountQuery: tally.itemCountQueries += 1
        case .other: tally.otherFetches += 1
        }
    }

    public func reset() {
        tally = Tally()
    }

    /// Runs `body` with recording enabled and returns what it did to the store.
    ///
    /// Nesting is not supported and not needed: a measurement asks one question about one code path.
    @discardableResult
    public func measure<Value>(_ body: () throws -> Value) rethrows -> (value: Value, tally: Tally) {
        reset()
        isRecording = true
        defer { isRecording = false }

        let value = try body()
        return (value, tally)
    }

    /// The `async` form, for measuring a path that awaits.
    @discardableResult
    public func measure<Value>(_ body: () async throws -> Value) async rethrows -> (value: Value, tally: Tally) {
        reset()
        isRecording = true
        defer { isRecording = false }

        let value = try await body()
        return (value, tally)
    }
}

import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation

/// What Elephruit already knows about a few of the synthetic calendar's meetings.
///
/// ### Why this is separate from the rest of the sample data
/// Because it is the only sample data that points *outside* the store. Everything else — tasks,
/// people, notes — is self-contained and true whatever else is switched on. A meeting record names
/// an event by identity, and if that event does not exist the record is a lost meeting: a row about
/// something nobody can open. That is a real state the app handles deliberately, and it is not a
/// state a sample library should be in by default.
///
/// So this is seeded by the composition root, and only when the synthetic calendar is the one
/// running. See `AppEnvironment`.
///
/// ### What it demonstrates
/// The three things a day's plan says about a meeting that the calendar itself cannot: that
/// something has been written down before it, that there is still something to do before walking in,
/// and that a person on the invitation is somebody with a history.
@MainActor
public enum MeetingSampleData {
    /// Identifiers from ``CalendarFixtures``. Stable, because those events are not recurring and so
    /// their identity is the identifier alone.
    private static let designReview = "fixture.design"
    private static let oneToOne = "fixture.oneToOne"

    public static func populate(services: AppServices) throws(AppError) {
        let items = services.items
        let clock = services.dateProvider

        // MARK: A meeting somebody has prepared for

        let review = try meeting(
            named: "Design review",
            identityKey: designReview,
            startingAt: clock.calendar.date(byAdding: .hour, value: 10, to: clock.startOfToday),
            in: services
        )
        try items.update(review) { item in
            item.body = """
                ## Before
                Bring the two pricing tiers and the objection Maya raised last month.

                ## After
                """
        }

        let prepare = try items.create(
            ItemDraft(kind: .task, title: "Print the pricing comparison")
        )
        try items.link(prepare, to: review, kind: .related)
        try services.tasks.commit(prepare, to: clock.startOfToday)

        let done = try items.create(ItemDraft(kind: .task, title: "Book Room 2"))
        try items.link(done, to: review, kind: .related)
        _ = try services.tasks.complete(done)

        // MARK: A meeting with somebody the library knows well

        let oneToOneMeeting = try meeting(
            named: "1:1 with Maya",
            identityKey: oneToOne,
            startingAt: clock.calendar.date(byAdding: .hour, value: 11, to: clock.startOfToday),
            in: services
        )

        // Linked by hand rather than matched from the invitation, which is the other way somebody
        // ends up on a meeting — and the case that proves the two do not produce a duplicate.
        var query = ItemQuery()
        query.kinds = [.person]
        if let maya = try items.items(matching: query).first(where: { $0.displayTitle == "Maya Chen" }) {
            try items.link(oneToOneMeeting, to: maya, kind: .participant)
        }

        Diagnostics.features.info("Loaded meeting sample data for the synthetic calendar")
    }

    /// A meeting item pointing at one of the fixture's events.
    private static func meeting(
        named title: String,
        identityKey: String,
        startingAt start: Date?,
        in services: AppServices
    ) throws(AppError) -> Item {
        let created = try services.items.create(ItemDraft(kind: .meeting, title: title))
        try services.items.update(created) { item in
            let reference = EventReference(
                identityKey: identityKey,
                cachedTitle: title,
                startAt: start,
                endAt: start?.addingTimeInterval(3_600)
            )
            reference.lastRefreshedAt = services.dateProvider.now
            reference.item = item
            services.context.insert(reference)
        }
        return created
    }
}

extension AppServices {
    /// Seeds what the app knows about the synthetic calendar's meetings.
    ///
    /// Called only when that calendar is the one running — see ``MeetingSampleData`` for why this is
    /// not part of `loadSampleData()`. Refuses outside development mode on the same terms as every
    /// other seeding entry point, so a release build cannot be talked into writing fiction.
    public func loadMeetingSampleData() {
        guard isDevelopmentMode else {
            Diagnostics.features.error("Meeting sample data requested outside development mode; refused")
            return
        }

        // Idempotent by construction: a second call would create a second meeting item for the same
        // event, and two records for one meeting is precisely the duplication this page promises not
        // to produce.
        let existing = (try? eventLinks.annotatedKeys(among: [
            EventIdentity(externalIdentifier: "fixture.design"),
        ])) ?? []
        guard existing.isEmpty else { return }

        let seeded = perform { try MeetingSampleData.populate(services: self) }
        guard seeded else { return }
        refreshDerivedState()
    }
}

import ElephruitCore
import Foundation
import Testing

private let clock = FixedDateProvider.reference
private var calendar: Calendar { clock.calendar }
private var now: Date { clock.now }

private func day(_ offset: Int) -> Date { clock.startOfDay(daysFromToday: offset) }

private func task(_ configure: (inout TaskFacts) -> Void = { _ in }) -> TaskFacts {
    var facts = TaskFacts(title: "A task", hasHome: true, createdAt: now, updatedAt: now)
    configure(&facts)
    return facts
}

@Suite("Smart lists match what they say they match")
struct SmartListMatchingTests {
    @Test("A list with no rules still excludes finished work by default")
    func resolvedWorkIsExcludedByDefault() {
        let filter = TaskFilter()
        let done = task {
            $0.status = .completed
            $0.completedAt = now
        }
        #expect(!filter.matches(done, now: now, calendar: calendar))
        #expect(filter.matches(task(), now: now, calendar: calendar))
    }

    @Test("Scope is separate from the rules, so a log can be built without a status rule")
    func includesResolvedIsAScope() {
        let filter = TaskFilter(rules: [.completedWithin(days: 7)], includesResolved: true)
        let done = task {
            $0.status = .completed
            $0.completedAt = day(-2)
        }
        #expect(filter.matches(done, now: now, calendar: calendar))
    }

    @Test("“All of” requires every rule")
    func allRequiresEverything() {
        let filter = TaskFilter(match: .all, rules: [.flagged(true), .hasDeadline(true)])

        #expect(!filter.matches(task { $0.isFlagged = true }, now: now, calendar: calendar))
        #expect(
            filter.matches(
                task {
                    $0.isFlagged = true
                    $0.deadlineAt = day(3)
                },
                now: now,
                calendar: calendar
            )
        )
    }

    @Test("“Any of” needs one")
    func anyNeedsOne() {
        let filter = TaskFilter(match: .any, rules: [.flagged(true), .waiting])
        #expect(filter.matches(task { $0.isFlagged = true }, now: now, calendar: calendar))
        #expect(!filter.matches(task(), now: now, calendar: calendar))
    }

    @Test("Overdue means a passed deadline, never a passed start date")
    func overdueIsAboutDeadlines() {
        let filter = TaskFilter(rules: [.overdue])
        #expect(filter.matches(task { $0.deadlineAt = day(-1) }, now: now, calendar: calendar))
        #expect(!filter.matches(task { $0.startAt = day(-30) }, now: now, calendar: calendar))
    }

    @Test("“Within N days” looks forward only")
    func withinLooksForward() {
        let filter = TaskFilter(rules: [.deadlineWithin(days: 7)])
        #expect(filter.matches(task { $0.deadlineAt = day(7) }, now: now, calendar: calendar))
        #expect(!filter.matches(task { $0.deadlineAt = day(8) }, now: now, calendar: calendar))
        #expect(!filter.matches(task { $0.deadlineAt = day(-1) }, now: now, calendar: calendar))
    }

    @Test("“No date” means none of the three")
    func noDateMeansNoneOfThree() {
        let filter = TaskFilter(rules: [.hasNoDate])
        #expect(filter.matches(task(), now: now, calendar: calendar))
        #expect(!filter.matches(task { $0.startAt = day(1) }, now: now, calendar: calendar))
        #expect(!filter.matches(task { $0.deadlineAt = day(1) }, now: now, calendar: calendar))
        #expect(!filter.matches(task { $0.reminderAt = day(1) }, now: now, calendar: calendar))
    }

    @Test("A person rule matches whether they are linked or waited on")
    func personRuleCoversBothWays() {
        let maya = UUID()
        let filter = TaskFilter(rules: [.relatedPerson(maya)])

        #expect(filter.matches(task { $0.relatedPersonIDs = [maya] }, now: now, calendar: calendar))
        #expect(filter.matches(task { $0.waitingOnPersonID = maya }, now: now, calendar: calendar))
        #expect(!filter.matches(task { $0.relatedPersonIDs = [UUID()] }, now: now, calendar: calendar))
    }

    @Test("Text is matched against the folded projection the store already keeps")
    func textMatching() {
        let filter = TaskFilter(rules: [.text("Renew")])
        let match = task { $0.searchText = TextNormalizer.foldedForMatching("Renew the insurance") }
        #expect(filter.matches(match, now: now, calendar: calendar))
        #expect(!filter.matches(task { $0.searchText = "something else" }, now: now, calendar: calendar))
    }

    @Test("An unreadable rule narrows an “all” list and is skipped by an “any” list")
    func unrecognisedRulesFailSafe() {
        let strict = TaskFilter(match: .all, rules: [.flagged(true), .unrecognised(name: "fromTheFuture")])
        let loose = TaskFilter(match: .any, rules: [.flagged(true), .unrecognised(name: "fromTheFuture")])
        let flagged = task { $0.isFlagged = true }

        // Both readings show *less* than the author asked for, never more.
        #expect(!strict.matches(flagged, now: now, calendar: calendar))
        #expect(loose.matches(flagged, now: now, calendar: calendar))
        #expect(strict.unrecognisedRules.count == 1)
    }
}

@Suite("Smart lists survive being stored")
struct SmartListCodingTests {
    @Test("Every rule shape round-trips")
    func roundTrip() {
        let filter = TaskFilter(
            match: .any,
            rules: [
                .lifecycle([.active, .waiting]),
                .flagged(true),
                .priority([.high, .low]),
                .committedToToday,
                .waiting,
                .overdue,
                .deadlineWithin(days: 3),
                .hasDeadline(false),
                .hasStartDate(true),
                .startsWithin(days: 14),
                .hasReminder(true),
                .hasNoDate,
                .completedWithin(days: 30),
                .createdWithin(days: 1),
                .area(UUID()),
                .project(UUID()),
                .list(UUID()),
                .section(UUID()),
                .tag("work/clients"),
                .unfiled,
                .relatedPerson(UUID()),
                .waitingOnPerson(UUID()),
                .linkedToAnyPerson,
                .source(.quickCapture),
                .syncState([.conflicted, .externalMissing]),
                .syncNeedsAttention,
                .hasAttachments(true),
                .repeating(true),
                .hasSubtasks(false),
                .text("budget"),
            ],
            includesResolved: true
        )

        #expect(TaskFilter.decode(from: filter.encoded()) == filter)
    }

    @Test("A rule from a newer build decodes as unrecognised rather than throwing the list away")
    func forwardCompatibility() throws {
        let json = Data(
            """
            {"match":"all","includesResolved":false,"rules":[{"name":"flagged","value":true},{"name":"energyLevel","value":true}]}
            """.utf8
        )
        let filter = try #require(TaskFilter.decode(from: json))

        #expect(filter.rules.count == 2)
        #expect(filter.unrecognisedRules == [.unrecognised(name: "energyLevel")])
    }

    @Test("Unreadable data reads as no filter at all")
    func corruptData() {
        #expect(TaskFilter.decode(from: Data("not json".utf8)) == nil)
        #expect(TaskFilter.decode(from: nil) == nil)
    }
}

@Suite("The built-in smart lists are ordinary smart lists")
struct BuiltInSmartListTests {
    @Test("Every built-in has rules, so none of them silently shows the whole library")
    func nothingIsUnconstrained() {
        for list in BuiltInSmartList.all {
            #expect(!list.filter.isUnconstrained, "\(list.title) has no rules")
            #expect(list.filter.unrecognisedRules.isEmpty, "\(list.title) has a rule this build cannot read")
        }
    }

    @Test("Identifiers are unique, so a sidebar selection cannot be ambiguous")
    func identifiersAreUnique() {
        #expect(Set(BuiltInSmartList.all.map(\.id)).count == BuiltInSmartList.all.count)
    }

    @Test("Recently Completed is the only one that reaches into finished work, plus sync issues")
    func onlyLogsIncludeResolved() {
        let including = BuiltInSmartList.all.filter(\.filter.includesResolved).map(\.id)
        #expect(Set(including) == ["recently-completed", "sync-issues"])
    }

    @Test("Overdue finds a passed deadline and ignores a passed start date")
    func overdueBuiltIn() throws {
        let list = try #require(BuiltInSmartList.list(id: "overdue"))
        #expect(list.filter.matches(task { $0.deadlineAt = day(-3) }, now: now, calendar: calendar))
        #expect(!list.filter.matches(task { $0.startAt = day(-3) }, now: now, calendar: calendar))
    }
}

@Suite("Repeating tasks roll forward without destroying the series")
struct RecurrenceAdvanceTests {
    @Test("A schedule-anchored task moves from its scheduled date, however late it was finished")
    func scheduleAnchor() throws {
        let facts = task { $0.deadlineAt = day(0) }
        let rule = RecurrenceRule(frequency: .monthly, anchor: .schedule)
        // Finished four days late.
        let advance = try #require(
            TaskRecurrence.advance(
                facts, rule: rule, completedAt: day(4), occurrencesSoFar: 0, calendar: calendar
            )
        )

        // Next month from the *scheduled* date. Being late does not move next month's rent.
        let expected = calendar.date(byAdding: .month, value: 1, to: day(0))
        #expect(advance.deadlineAt == expected)
    }

    @Test("A completion-anchored task moves from when it was actually done")
    func completionAnchor() throws {
        let facts = task { $0.deadlineAt = day(0) }
        let rule = RecurrenceRule(frequency: .daily, interval: 3, anchor: .completion)
        let advance = try #require(
            TaskRecurrence.advance(
                facts, rule: rule, completedAt: day(4), occurrencesSoFar: 0, calendar: calendar
            )
        )

        #expect(advance.deadlineAt == day(7))
    }

    @Test("A start date and a deadline keep their spacing")
    func spacingSurvives() throws {
        let facts = task {
            $0.startAt = day(0)
            $0.deadlineAt = day(4)
        }
        let rule = RecurrenceRule(frequency: .weekly)
        let advance = try #require(
            TaskRecurrence.advance(
                facts, rule: rule, completedAt: day(4), occurrencesSoFar: 0, calendar: calendar
            )
        )

        // The deadline is the anchor, so it lands on the computed occurrence and the runway follows.
        #expect(advance.deadlineAt == day(11))
        #expect(advance.startAt == day(7))
    }

    @Test("A date the task does not have is never invented")
    func absentDatesStayAbsent() throws {
        let facts = task { $0.deadlineAt = day(0) }
        let advance = try #require(
            TaskRecurrence.advance(
                facts,
                rule: RecurrenceRule(frequency: .weekly),
                completedAt: day(0),
                occurrencesSoFar: 0,
                calendar: calendar
            )
        )

        #expect(advance.startAt == nil)
        #expect(advance.reminderAt == nil)
    }

    @Test("A reminder keeps its time of day across the roll-forward")
    func reminderKeepsItsTime() throws {
        let fireAt = try #require(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day(0)))
        let facts = task {
            $0.deadlineAt = day(0)
            $0.reminderAt = fireAt
        }
        let advance = try #require(
            TaskRecurrence.advance(
                facts,
                rule: RecurrenceRule(frequency: .weekly),
                completedAt: day(0),
                occurrencesSoFar: 0,
                calendar: calendar
            )
        )
        let next = try #require(advance.reminderAt)

        #expect(calendar.component(.hour, from: next) == 9)
        #expect(calendar.component(.minute, from: next) == 0)
    }

    @Test("A series with a count ends when the count is reached")
    func occurrenceLimit() {
        let facts = task { $0.deadlineAt = day(0) }
        let rule = RecurrenceRule(frequency: .daily, end: .afterOccurrences(3))

        #expect(
            TaskRecurrence.advance(
                facts, rule: rule, completedAt: day(0), occurrencesSoFar: 2, calendar: calendar
            ) != nil
        )
        #expect(
            TaskRecurrence.isFinalOccurrence(
                facts, rule: rule, completedAt: day(0), occurrencesSoFar: 3, calendar: calendar
            )
        )
    }

    @Test("A series with an end date stops after it")
    func endDate() {
        let facts = task { $0.deadlineAt = day(0) }
        let rule = RecurrenceRule(frequency: .weekly, end: .onDate(day(3)))

        #expect(
            TaskRecurrence.isFinalOccurrence(
                facts, rule: rule, completedAt: day(0), occurrencesSoFar: 0, calendar: calendar
            )
        )
    }

    @Test("A weekly repeat keeps its weekday across a daylight-saving change")
    func daylightSaving() throws {
        // British Summer Time ends on 25 October 2026, a Sunday. A weekly Friday task either side of
        // it must stay on Friday rather than sliding by the hour the clocks moved.
        var london = Calendar(identifier: .gregorian)
        london.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        london.firstWeekday = 1

        let beforeChange = try #require(
            london.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 9))
        )
        let facts = TaskFacts(deadlineAt: beforeChange, hasHome: true)
        let advance = try #require(
            TaskRecurrence.advance(
                facts,
                rule: RecurrenceRule(frequency: .weekly),
                completedAt: beforeChange,
                occurrencesSoFar: 0,
                calendar: london
            )
        )
        let next = try #require(advance.deadlineAt)

        #expect(london.component(.weekday, from: next) == 6)  // Friday
        #expect(london.component(.day, from: next) == 30)
    }

    @Test("Editing a repeat always offers the three scopes")
    func editScopes() {
        #expect(RecurrenceEditScope.allCases.count == 3)
        #expect(RecurrenceEditScope.allCases.allSatisfy { !$0.explanation.isEmpty })
    }
}

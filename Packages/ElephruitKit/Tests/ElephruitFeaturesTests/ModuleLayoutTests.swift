import CoreGraphics
import ElephruitDesign
@testable import ElephruitFeatures
import Foundation
import Testing

/// One module's columns cannot move another module's.
///
/// The bug this suite exists for is worth stating, because it is invisible in any single screenshot:
/// AppKit's split view keeps its divider wherever it was last dragged, and the shell had one set of
/// widths for the whole app. So widening the pane to read somebody's profile also widened it in the
/// calendar, where the same 720 points was an empty box captioned "Nothing selected" sitting where
/// the month should have been. Nothing in the calendar's code was wrong; it had simply never been
/// asked.
@Suite("Module shell layout")
@MainActor
struct ModuleLayoutTests {
    private func store() -> ModuleLayoutStore {
        let suite = "ModuleLayoutTests-\(UUID().uuidString)"
        // A throwaway suite per test: these persist, and a test that shares preferences with the
        // next one passes or fails depending on the order they ran in.
        return ModuleLayoutStore(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    private let wideWindow: CGFloat = 1800

    // MARK: - The regression

    /// The exact sequence from the report: use a wide People pane, switch to Calendar.
    @Test("A wide People pane does not follow the user into the calendar")
    func peopleWidthDoesNotLeakIntoCalendar() {
        let layout = store()
        layout.setWidth(760, of: .detail, in: .records, available: wideWindow)

        #expect(layout.width(of: .detail, in: .records, available: wideWindow) == 760)
        #expect(
            layout.width(of: .detail, in: .calendar, available: wideWindow) == 0,
            "the calendar has no detail column to inherit one"
        )
    }

    @Test("The calendar canvas gets the width, not the pane beside it")
    func calendarCanvasIsTheWidestThing() {
        let layout = store()
        let canvas = layout.width(of: .primary, in: .calendar, available: wideWindow)
        let inspector = layout.width(of: .inspector, in: .calendar, available: wideWindow)

        #expect(canvas > inspector * 2)
        #expect(AppModule.calendar.shellLayout.detail.isAvailable == false)
    }

    @Test("People keeps the widest detail pane in the app")
    func peopleIsTheWidest() {
        let layout = store()
        let people = layout.width(of: .detail, in: .records, available: wideWindow)

        for module in AppModule.allCases where module != .records && module != .notes {
            let other = layout.width(of: .detail, in: module, available: wideWindow)
            #expect(people >= other, "\(module) claims more room than a person's profile")
        }
    }

    @Test("The contact list has its own width, separate from the profile")
    func contactListIsSizedSeparately() {
        let layout = store()
        layout.setWidth(760, of: .detail, in: .records, available: wideWindow)

        #expect(
            layout.width(of: .primary, in: .records, available: wideWindow)
                == AppModule.records.shellLayout.primary.ideal,
            "widening the profile moved the contact list"
        )
    }

    @Test("The contact list stays compact beside the profile")
    func contactListStaysCompact() {
        let bounds = AppModule.records.shellLayout.primary

        #expect(bounds.ideal == 280)
        #expect(bounds.maximum == 340)
        #expect(bounds.ideal < AppModule.records.shellLayout.detail.width.ideal)
    }

    /// The complaint this answers: AppKit restores its remembered divider a beat after the window
    /// is up, without consulting the declared constraints, so the People list could open at a
    /// thousand points against a declared maximum of 340. The shell corrects a settled width that
    /// exceeds this ceiling; a column with no declared maximum must never be "corrected".
    @Test("The ceiling a laid-out column is checked against is the declared maximum")
    func declaredCeilingMatchesThePolicy() {
        let people = AppModule.records.shellLayout

        #expect(people.declaredCeiling(of: .primary) == 340)
        // The profile is unbounded on purpose — no laid-out width of it is ever a violation.
        #expect(people.declaredCeiling(of: .detail) == .greatestFiniteMagnitude)

        // A canvas module's primary column takes the window; it has no ceiling to enforce.
        #expect(AppModule.calendar.shellLayout.declaredCeiling(of: .primary) == .greatestFiniteMagnitude)
    }

    /// The complaint this answers: the list was excessively wide, the profile was cramped, and the
    /// pane on the far right took a permanent slice of both.
    @Test("A person's profile is the column that takes the spare width")
    func theProfileIsTheFlexibleColumn() {
        let layout = AppModule.records.shellLayout

        // No ceiling, which is what makes it the column the shell settles last and hands the
        // remainder to. Every other column in the module is firmly bounded.
        #expect(layout.detail.width.maximum == nil)
        #expect(layout.primary.maximum != nil)
        #expect(layout.inspector.width.maximum != nil)

        let wide = layout.widths(
            windowWidth: 2400,
            sidebarWidth: 208,
            userWantsInspector: true,
            hasSelection: true
        )

        let profile = wide.detail ?? 0
        #expect(wide.primary <= layout.primary.maximum ?? 0)
        #expect(profile > wide.primary * 3, "the list is claiming room the profile needs")
        #expect(profile > (wide.inspector ?? 0) * 3)
        #expect(wide.total == 2400, "a column short of the window leaves a strip of nothing")
    }

    @Test("The inspector does not open itself every time a name is clicked")
    func theInspectorIsContextual() {
        let inspector = AppModule.records.shellLayout.inspector

        // It hides when nothing is selected *and* declines to reappear on the next selection. Both
        // are needed: `hidesWhenNothingSelected` alone made every click reopen a pane the user had
        // closed twenty names ago, which is a fourth column with a dismiss button.
        #expect(inspector.hidesWhenNothingSelected)
        #expect(inspector.opensAfterSelection == false)
        #expect(inspector.shouldOpenAfterSelection() == false)

        // And it is not offered at all until the profile already has room. Below this the
        // arithmetic can satisfy every minimum and still leave the main content the narrowest
        // thing on the screen.
        #expect(
            inspector.isVisible(userWants: true, hasSelection: true, windowWidth: 1200) == false
        )
        #expect(inspector.isVisible(userWants: true, hasSelection: true, windowWidth: 1400))
    }

    @Test("Every module's widths are independent")
    func modulesDoNotShareWidths() {
        let layout = store()
        for module in AppModule.allCases where module.shellLayout.detail.isAvailable {
            layout.setWidth(module.shellLayout.detail.width.minimum + 7, of: .detail, in: module, available: wideWindow)
        }

        for module in AppModule.allCases where module.shellLayout.detail.isAvailable {
            #expect(
                layout.width(of: .detail, in: module, available: wideWindow)
                    == module.shellLayout.detail.width.minimum + 7
            )
        }
    }

    @Test("Switching back and forth changes nothing")
    func repeatedSwitchingIsStable() {
        let layout = store()
        layout.setWidth(700, of: .detail, in: .records, available: wideWindow)
        layout.setWidth(500, of: .detail, in: .notes, available: wideWindow)

        for _ in 0..<20 {
            #expect(layout.width(of: .detail, in: .records, available: wideWindow) == 700)
            #expect(layout.width(of: .detail, in: .calendar, available: wideWindow) == 0)
            #expect(layout.width(of: .detail, in: .notes, available: wideWindow) == 500)
        }
    }

    // MARK: - Clamping what was restored

    /// A width dragged on a 6K display and restored into a laptop window must not push the list and
    /// the sidebar into a fight over the remaining hundred points.
    @Test("A width restored from a larger window is clamped to this one")
    func restoredWidthIsClampedToTheWindow() {
        let layout = store()
        layout.setWidth(900, of: .detail, in: .records, available: 3200)

        let onALaptop = layout.width(of: .detail, in: .records, available: 1280)
        #expect(onALaptop <= 1280)
        #expect(onALaptop >= AppModule.records.shellLayout.detail.width.minimum)
    }

    /// Clamping happens on the way out, so the original request survives a visit to a small window.
    @Test("A clamped width is not forgotten")
    func clampingIsNotDestructive() {
        let layout = store()
        layout.setWidth(800, of: .detail, in: .records, available: 3200)
        _ = layout.width(of: .detail, in: .records, available: 900)

        #expect(layout.width(of: .detail, in: .records, available: 3200) == 800)
    }

    @Test("A width outside the module's own range is brought back inside it")
    func obsoleteWidthsAreClamped() {
        let layout = store()
        let bounds = AppModule.notes.shellLayout.detail.width
        layout.setWidth(4000, of: .detail, in: .notes, available: wideWindow)

        let resolved = layout.width(of: .detail, in: .notes, available: wideWindow)
        #expect(resolved == bounds.maximum)
        #expect(resolved >= bounds.minimum)
    }

    @Test("A pane never resolves below its minimum, even in a window that cannot hold it")
    func minimumWins() {
        let layout = store()
        let minimum = AppModule.records.shellLayout.detail.width.minimum

        #expect(layout.width(of: .detail, in: .records, available: 200) == minimum)
    }

    // MARK: - Persistence

    @Test("Widths survive a relaunch, per module")
    func widthsPersist() throws {
        let suite = "ModuleLayoutTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removeSuite(named: suite) }

        let first = ModuleLayoutStore(defaults: defaults)
        first.setWidth(700, of: .detail, in: .records, available: wideWindow)
        first.setWidth(420, of: .detail, in: .notes, available: wideWindow)

        let afterRelaunch = ModuleLayoutStore(defaults: defaults)
        #expect(afterRelaunch.width(of: .detail, in: .records, available: wideWindow) == 700)
        #expect(afterRelaunch.width(of: .detail, in: .notes, available: wideWindow) == 420)
    }

    /// A preference file written by a build that had a module this one does not must not cost the
    /// user the rest of their layout.
    @Test("A module this build does not know is skipped, not fatal")
    func unknownModulesAreIgnored() throws {
        let suite = "ModuleLayoutTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removeSuite(named: suite) }

        defaults.set(
            [
                "someFutureModule": ["detail": 500.0],
                "people": ["detail": 640.0],
                "notes": ["someFutureColumn": 300.0],
            ],
            forKey: "layout.moduleColumnWidths"
        )

        let loaded = ModuleLayoutStore(defaults: defaults)
        #expect(loaded.width(of: .detail, in: .records, available: wideWindow) == 640)
        #expect(
            loaded.width(of: .detail, in: .notes, available: wideWindow)
                == AppModule.notes.shellLayout.detail.width.ideal
        )
    }

    @Test("Dragging a column back to its default stops overriding it")
    func settingTheDefaultClearsTheOverride() {
        let layout = store()
        let ideal = AppModule.notes.shellLayout.detail.width.ideal

        layout.setWidth(800, of: .detail, in: .notes, available: wideWindow)
        layout.setWidth(ideal, of: .detail, in: .notes, available: wideWindow)

        // Proven by changing what the default would resolve to: an override would survive this and
        // a cleared one follows the new answer.
        #expect(layout.width(of: .detail, in: .notes, available: 700) <= 700)
    }

    // MARK: - Visibility

    @Test("The calendar's inspector is not there until an event is")
    func calendarInspectorHidesWhenEmpty() {
        let policy = AppModule.calendar.shellLayout.inspector

        #expect(!policy.isVisible(userWants: true, hasSelection: false, windowWidth: wideWindow))
        #expect(policy.isVisible(userWants: true, hasSelection: true, windowWidth: wideWindow))
    }

    /// People is the opposite case on purpose: an empty person pane is where the "no one selected"
    /// state lives, and collapsing it would make the window jump every time the list was cleared.
    @Test("The person pane stays when nothing is selected")
    func peopleDetailStaysWhenEmpty() {
        let policy = AppModule.records.shellLayout.detail
        #expect(policy.isVisible(userWants: true, hasSelection: false, windowWidth: wideWindow))
    }

    @Test("A narrow window drops the pane and a wide one brings it back")
    func narrowWindowsDropTheInspector() {
        let policy = AppModule.records.shellLayout.inspector
        let threshold = policy.compactWindowWidth

        #expect(!policy.isVisible(userWants: true, hasSelection: true, windowWidth: threshold - 1))
        #expect(policy.isVisible(userWants: true, hasSelection: true, windowWidth: threshold))
    }

    @Test("Closing a pane is not undone by the next selection")
    func aClosedPaneStaysClosed() {
        // People's context sidebar does not hide itself when empty, so nothing should reopen it.
        #expect(!AppModule.records.shellLayout.detail.shouldOpenAfterSelection())
        // The calendar's does, so selecting an event should bring it back.
        #expect(AppModule.calendar.shellLayout.inspector.shouldOpenAfterSelection())
    }

    @Test("A module with no such pane never shows one")
    func unavailablePanesStayAway() {
        #expect(
            !AppModule.calendar.shellLayout.detail
                .isVisible(userWants: true, hasSelection: true, windowWidth: wideWindow)
        )
    }

    // MARK: - Narrow windows

    @Test("A window too narrow for every column drops them from the trailing edge inwards")
    func columnsAreDroppedInPriorityOrder() {
        let layout = AppModule.records.shellLayout
        let sidebar = Theme.Size.sidebarIdealWidth

        #expect(layout.columns(fittingWindowOfWidth: 1800, sidebarWidth: sidebar).count == 4)

        let cramped = layout.columns(fittingWindowOfWidth: 1000, sidebarWidth: sidebar)
        #expect(cramped.contains(.primary), "the contact list is the last thing to go")
        #expect(!cramped.contains(.inspector))

        let tiny = layout.columns(fittingWindowOfWidth: 600, sidebarWidth: sidebar)
        #expect(tiny == [.sidebar, .primary])
    }

    @Test("The calendar keeps its canvas at every width")
    func calendarKeepsItsCanvas() {
        let layout = AppModule.calendar.shellLayout
        for width in stride(from: 400 as CGFloat, through: 2400, by: 100) {
            let columns = layout.columns(fittingWindowOfWidth: width, sidebarWidth: 224)
            #expect(columns.contains(.primary), "at \(width)")
            #expect(!columns.contains(.detail), "at \(width)")
        }
    }

    // MARK: - Policy sanity

    @Test("Every module states a coherent policy")
    func policiesAreWellFormed() {
        for module in AppModule.allCases {
            let layout = module.shellLayout

            #expect(layout.primary.minimum > 0, "\(module) has no primary column")
            #expect(layout.primary.ideal >= layout.primary.minimum, "\(module)")

            for pane in [layout.detail, layout.inspector] where pane.isAvailable {
                #expect(pane.width.minimum > 0, "\(module)")
                #expect(pane.width.ideal >= pane.width.minimum, "\(module)")
                if let maximum = pane.width.maximum {
                    #expect(maximum >= pane.width.ideal, "\(module)")
                }
            }
        }
    }

    /// A window has to be able to hold the sidebar, the primary column and the detail column at
    /// their minimums by the time the module says the detail column is allowed — otherwise the
    /// threshold promises a layout that cannot be drawn.
    @Test("A module's compact threshold is wide enough for the columns it lets through")
    func compactThresholdsAreAchievable() {
        for module in AppModule.allCases {
            let layout = module.shellLayout
            guard layout.detail.isAvailable else { continue }

            let needed = Theme.Size.sidebarMinWidth + layout.primary.minimum + layout.detail.width.minimum
            #expect(
                layout.detail.compactWindowWidth >= needed,
                "\(module) opens its detail pane at \(layout.detail.compactWindowWidth) but needs \(needed)"
            )
        }
    }

    // MARK: - Telling a drag from a resize

    @Test("A column that moved while the window did not is a drag")
    func dragIsDetected() {
        var detector = PaneDragDetector()
        _ = detector.isUserDrag(columnWidth: 500, windowWidth: 1600)

        let moved = detector.isUserDrag(columnWidth: 560, windowWidth: 1600)
        #expect(moved)
    }

    @Test("A column that moved because the window did is not")
    func resizeIsNotADrag() {
        var detector = PaneDragDetector()
        _ = detector.isUserDrag(columnWidth: 500, windowWidth: 1600)

        let moved = detector.isUserDrag(columnWidth: 560, windowWidth: 1720)
        #expect(!moved)
    }

    @Test("The first sample is never a drag")
    func firstSampleIsNotADrag() {
        var detector = PaneDragDetector()
        let first = detector.isUserDrag(columnWidth: 500, windowWidth: 1600)
        #expect(!first)
    }

    @Test("A sub-point difference between layout passes is not a drag")
    func roundingIsNotADrag() {
        var detector = PaneDragDetector()
        _ = detector.isUserDrag(columnWidth: 500, windowWidth: 1600)

        let jitter = detector.isUserDrag(columnWidth: 500.4, windowWidth: 1600)
        #expect(!jitter)
    }
}

/// Every module, at every window size, with and without a selection and an inspector.
///
/// ### Why this is a test and not a set of screenshots
/// Because the fault was never visible in one screenshot. Each pane cleared its own threshold; what
/// was wrong was the sum, and the sum is only wrong in some combinations of module, window width,
/// selection and inspector. Enumerating them is the only way to know none of them is the broken one,
/// and a person cannot enumerate forty-eight layouts by eye.
///
/// The three widths are the ones worth naming: the app's own minimum window, a typical laptop, and
/// a large display like the one the fault was reported from.
@Suite("Every layout at every size")
@MainActor
struct LayoutAuditTests {
    private var sidebar: CGFloat {
        SidebarMetrics.minimumWidth(fittingTitles: SidebarRegistry.nonTruncatingTitles)
    }

    private let windows: [(name: String, width: CGFloat)] = [
        ("minimum window", 900),
        ("laptop", 1440),
        ("large display", 1920),
    ]

    /// Every layout the shell can be in, named so a failure says which one.
    private func everyLayout() -> [(name: String, layout: ModuleShellLayout)] {
        var all: [(String, ModuleShellLayout)] = [
            ("Inbox and the rest of primary navigation", PrimaryNavigationLayout.shell),
            ("Today", TodayLayout.shell),
        ]
        all.append(contentsOf: AppModule.displayOrder.map { ($0.title, $0.shellLayout) })
        return all.map { (name: $0.0, layout: $0.1) }
    }

    /// The floor below which a content pane is a strip rather than a pane.
    ///
    /// No content column in the app declares a minimum under 240. A column narrower than this is the
    /// symptom that was reported — an editor at 118 points, an empty state wrapping "Nothing
    /// selected" one syllable to a line.
    ///
    /// The sidebar is exempt and is meant to be: it is primary navigation, it is deliberately
    /// compact, and its own minimum is derived from the titles it must not truncate rather than from
    /// a number here. It is held to that minimum by the second assertion below.
    private let readableFloor: CGFloat = 240

    @Test("No pane is ever narrower than a pane can usefully be")
    func nothingIsAStrip() {
        for (moduleName, layout) in everyLayout() {
            for window in windows {
                for wantsInspector in [true, false] {
                    for hasSelection in [true, false] {
                        let widths = layout.widths(
                            windowWidth: window.width,
                            sidebarWidth: sidebar,
                            userWantsInspector: wantsInspector,
                            hasSelection: hasSelection
                        )

                        let situation = """
                            \(moduleName), \(window.name) (\(Int(window.width))pt), \
                            inspector \(wantsInspector ? "on" : "off"), \
                            \(hasSelection ? "with" : "without") a selection
                            """

                        for pane in widths.present {
                            if pane.column != .sidebar {
                                #expect(
                                    pane.width >= readableFloor,
                                    "\(situation): the \(pane.column) column is \(pane.width)pt — \(widths)"
                                )
                            }
                            #expect(
                                pane.width >= layout.minimumWidth(of: pane.column, sidebarWidth: sidebar),
                                "\(situation): the \(pane.column) column is below its own declared minimum"
                            )
                        }
                    }
                }
            }
        }
    }

    @Test("The columns never add up to more window than there is")
    func nothingOverflows() {
        for (moduleName, layout) in everyLayout() {
            for window in windows {
                for wantsInspector in [true, false] {
                    let widths = layout.widths(
                        windowWidth: window.width,
                        sidebarWidth: sidebar,
                        userWantsInspector: wantsInspector,
                        hasSelection: true
                    )

                    #expect(
                        widths.total <= window.width,
                        "\(moduleName) at \(Int(window.width))pt asks for \(widths.total)pt — \(widths)"
                    )
                }
            }
        }
    }

    /// Requirement, stated as a test: an inspector that will not fit is not shown at all.
    @Test("A window too narrow for a usable inspector has none")
    func theInspectorGoesRatherThanShrinks() {
        for (moduleName, layout) in everyLayout() where layout.inspector.isAvailable {
            let widths = layout.widths(
                windowWidth: 900,
                sidebarWidth: sidebar,
                userWantsInspector: true,
                hasSelection: true
            )

            #expect(
                widths.inspector == nil,
                "\(moduleName) squeezes an inspector into the minimum window instead of hiding it"
            )
        }
    }

    /// The complaint about proportions: moving between modules should not reshape the window.
    ///
    /// Not identical — People really does want a wider profile than Notes wants an editor, and that
    /// is the point of a per-module policy — but within sight of each other, which "1,170 here and
    /// 340 there" was not.
    ///
    /// Only the modules that are the same *shape* are compared. A canvas — Calendar, Time — is one
    /// pane that is the module, so its middle column is the window and is supposed to be; holding it
    /// to the width of a contact list would be asserting the opposite of what the policy says.
    @Test("Switching between list modules does not reshape the window")
    func proportionsAreComparableAcrossModules() {
        let lists = everyLayout()
            .filter { $0.layout.detail.isAvailable }
            .map { entry in
                (
                    entry.name,
                    entry.layout.widths(
                        windowWidth: 1440,
                        sidebarWidth: sidebar,
                        userWantsInspector: false,
                        hasSelection: true
                    ).primary
                )
            }

        guard let narrowest = lists.min(by: { $0.1 < $1.1 }),
              let widest = lists.max(by: { $0.1 < $1.1 })
        else {
            Issue.record("No layouts to compare")
            return
        }

        #expect(
            widest.1 <= narrowest.1 * 2,
            "\(widest.0)'s list is \(widest.1)pt and \(narrowest.0)'s is \(narrowest.1)pt — that is a different window, not a different module"
        )
    }

    /// A canvas module has no editor by design, and that must stay a deliberate absence rather than
    /// becoming a strip when the arithmetic changes.
    @Test("A canvas module gets its canvas and no empty third column")
    func canvasModulesKeepTheirCanvas() {
        for module in [AppModule.calendar, .time] {
            let widths = module.shellLayout.widths(
                windowWidth: 1920,
                sidebarWidth: sidebar,
                userWantsInspector: false,
                hasSelection: false
            )

            #expect(widths.detail == nil, "\(module.title) has grown a detail column")
            #expect(
                widths.primary > 900,
                "\(module.title) is a canvas and should have the window — it has \(widths.primary)pt"
            )
        }
    }
}

/// What a relaunch does with widths that were never choices.
///
/// These are not invented numbers. They are what was actually in the user's preferences when this
/// was reported, written by a drag detector that read the frames of the shell's own animations as
/// deliberate resizes — a Notes list at 1,171.5 points against a declared maximum of 480, and an
/// editor at 118.5 against a minimum of 420. That detector is fixed, but what it wrote survives a
/// relaunch, so the store has to recognise a value that could never have come from a drag.
@Suite("Widths that could not have been chosen")
@MainActor
struct PersistedWidthHealingTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "PersistedWidthHealing-\(UUID().uuidString)") ?? .standard
    }

    private let key = "layout.moduleColumnWidths"

    @Test("A width beyond the module's own maximum is not restored")
    func impossibleWidthsAreDiscarded() {
        let store = defaults()
        store.set(
            [
                "notes": ["primary": 1171.5, "detail": 1101.5],
                "_primary": ["primary": 1382.5, "detail": 118.5],
            ],
            forKey: key
        )

        let layout = ModuleLayoutStore(defaults: store)

        // Each falls back to the module's own ideal rather than to the impossible stored number.
        #expect(layout.width(of: .primary, in: .notes, available: 2000) == AppModule.notes.shellLayout.primary.ideal)
        #expect(layout.width(of: .detail, in: .notes, available: 2000) == AppModule.notes.shellLayout.detail.width.ideal)
        #expect(layout.width(of: .primary, in: nil, available: 2000) == PrimaryNavigationLayout.shell.primary.ideal)
        #expect(layout.width(of: .detail, in: nil, available: 2000) == PrimaryNavigationLayout.shell.detail.width.ideal)
    }

    /// Healing happens on disk too, or every launch would rediscover the same rubbish.
    @Test("The discarded widths do not survive the launch that rejected them")
    func healingIsWrittenBack() {
        let store = defaults()
        store.set(["notes": ["primary": 1171.5]], forKey: key)

        _ = ModuleLayoutStore(defaults: store)

        let remaining = store.dictionary(forKey: key) as? [String: [String: Double]]
        #expect(remaining?["notes"]?["primary"] == nil)
    }

    /// The point is to reject what cannot have been a drag, not to forget what was one.
    @Test("A width the user really could have dragged to is kept")
    func legitimateWidthsSurvive() {
        let store = defaults()
        let chosen = AppModule.notes.shellLayout.primary.maximum ?? 480
        store.set(["notes": ["primary": Double(chosen) - 20]], forKey: key)

        let layout = ModuleLayoutStore(defaults: store)

        #expect(layout.width(of: .primary, in: .notes, available: 2000) == chosen - 20)
    }

    /// A width dragged on a larger display is still a preference, and still comes back whole when
    /// there is room for it — that rule is about the *window*, and is deliberately not touched here.
    @Test("A width from a bigger display is kept and clamped to today's room")
    func widthsFromLargerDisplaysAreStillHonoured() {
        let store = defaults()
        store.set(["people": ["detail": 800.0]], forKey: key)

        let layout = ModuleLayoutStore(defaults: store)

        #expect(layout.width(of: .detail, in: .records, available: 2000) == 800)
        #expect(layout.width(of: .detail, in: .records, available: 500) == 500)
    }
}

/// Whether the columns fit *together*, which is the question nobody was asking.
///
/// Every pane had a threshold of its own — "am I allowed at this window width?" — and every pane
/// could answer yes while the four of them added up to more window than there was. The result was
/// four columns each above its own bar, squeezed: a list at 1,170 points against a declared maximum
/// of 480, an editor at 118 against a minimum of 420, and an empty state wrapping one character to
/// a line.
@Suite("Columns that fit together")
@MainActor
struct ShellFitTests {
    /// What the sidebar takes from the others at the current text size.
    private var sidebar: CGFloat {
        SidebarMetrics.minimumWidth(fittingTitles: SidebarRegistry.nonTruncatingTitles)
    }

    /// The app's own minimum window — see `ElephruitApp`'s `.frame(minWidth: 900)`.
    private let minimumWindow: CGFloat = 900

    /// The one that decides whether the numbers in `ModuleLayoutPolicy` are coherent at all.
    ///
    /// If this fails, some module has asked for more than the smallest window the app will open at,
    /// and somebody using that window gets no editor — which is a decision to make deliberately
    /// rather than to discover.
    @Test("Every module holds a sidebar, a list and an editor at the minimum window size")
    func everyModuleFitsTheSmallestWindow() {
        for module in AppModule.displayOrder {
            let layout = module.shellLayout
            guard layout.detail.isAvailable else { continue }

            let needed = sidebar + layout.primary.minimum + layout.detail.width.minimum
            #expect(
                needed <= minimumWindow,
                "\(module.title) needs \(needed) points before it has an editor, and the window can be \(minimumWindow)"
            )

            let fitted = layout.columns(fittingWindowOfWidth: minimumWindow, sidebarWidth: sidebar)
            #expect(fitted.contains(.detail), "\(module.title) loses its editor at the minimum window")
        }
    }

    @Test("Primary navigation holds all three at the minimum window size too")
    func primaryNavigationFitsTheSmallestWindow() {
        let layout = PrimaryNavigationLayout.shell
        let fitted = layout.columns(fittingWindowOfWidth: minimumWindow, sidebarWidth: sidebar)

        #expect(fitted.contains(.primary))
        #expect(fitted.contains(.detail), "Inbox loses its editor at the minimum window")
    }

    /// Today is a canvas, on the same terms as the calendar and the time sheet.
    ///
    /// The failure this guards against is the one the calendar already had once: the thing a
    /// destination exists to show, drawn in a third of the window, beside a wide pane captioned
    /// "Nothing selected".
    @Test("Today takes the window rather than sitting in a list column")
    func todayIsACanvas() {
        let layout = TodayLayout.shell

        #expect(layout.primary.maximum == nil, "a canvas asks for what is left, not for a number")
        #expect(!layout.detail.isAvailable, "there is nothing for a third column to be about")

        for (name, width) in [("laptop", CGFloat(1440)), ("large display", CGFloat(1920))] {
            let widths = layout.widths(
                windowWidth: width,
                sidebarWidth: sidebar,
                userWantsInspector: false,
                hasSelection: false
            )
            #expect(widths.detail == nil, "Today grew a detail column at \(name)")
            #expect(
                widths.primary >= width - sidebar - 1,
                "Today left \(width - sidebar - widths.primary) points of nothing beside it at \(name)"
            )
        }
    }

    @Test("Today's inspector arrives with a selection and only when there is room")
    func todayInspectorFollowsItsPolicy() {
        let layout = TodayLayout.shell

        let empty = layout.widths(
            windowWidth: 1600, sidebarWidth: sidebar, userWantsInspector: true, hasSelection: false
        )
        #expect(empty.inspector == nil, "nothing is selected, so there is nothing to be about")

        let selected = layout.widths(
            windowWidth: 1600, sidebarWidth: sidebar, userWantsInspector: true, hasSelection: true
        )
        #expect(selected.inspector != nil)

        let narrow = layout.widths(
            windowWidth: 1000, sidebarWidth: sidebar, userWantsInspector: true, hasSelection: true
        )
        #expect(narrow.inspector == nil, "the day matters more than the pane describing one row of it")
    }

    @Test("The shell asks the selection, not only the module, which layout to wear")
    func selectionDecidesTheLayoutOutsideAModule() {
        let navigation = NavigationModel()

        navigation.select(.today)
        #expect(navigation.shellLayout == TodayLayout.shell)

        navigation.select(.inbox)
        #expect(navigation.shellLayout == PrimaryNavigationLayout.shell)

        // A superseded destination wears Today's layout, because it *is* Today.
        navigation.select(.upcoming)
        #expect(navigation.shellLayout == TodayLayout.shell)

        navigation.enterModule(.notes)
        #expect(navigation.shellLayout == AppModule.notes.shellLayout)
    }

    /// ⌘F replaces whatever the module shows with a results list and a reading pane, so the shell
    /// must wear a layout that *has* a reading pane — a canvas module's own layout would let a
    /// result be selected and never seen.
    @Test("Search wears the list-and-detail layout wherever it was invoked")
    func searchWearsThePrimaryLayout() {
        let navigation = NavigationModel()

        navigation.enterModule(.calendar)
        #expect(navigation.shellLayout == AppModule.calendar.shellLayout)

        navigation.beginSearch()
        #expect(navigation.shellLayout == PrimaryNavigationLayout.shell)

        navigation.endSearch()
        #expect(
            navigation.shellLayout == AppModule.calendar.shellLayout,
            "leaving search hands the module its own shape back"
        )

        // The override holds outside modules too — searching from Today must not keep the
        // day's canvas.
        navigation.leaveModule()
        navigation.select(.today)
        navigation.beginSearch()
        #expect(navigation.shellLayout == PrimaryNavigationLayout.shell)
    }

    /// The inspector goes first and the editor second, rather than everything narrowing at once.
    @Test("A narrowing window gives up the inspector before the editor")
    func dropOrder() {
        let layout = AppModule.notes.shellLayout

        let roomy = layout.columns(fittingWindowOfWidth: 1600, sidebarWidth: sidebar)
        #expect(roomy.contains(.detail))
        #expect(roomy.contains(.inspector))

        // Below the inspector's threshold, above the editor's.
        let middling = layout.columns(fittingWindowOfWidth: 1000, sidebarWidth: sidebar)
        #expect(middling.contains(.detail))
        #expect(!middling.contains(.inspector), "The inspector is what a narrow window gives up first")

        let tight = layout.columns(fittingWindowOfWidth: 700, sidebarWidth: sidebar)
        #expect(!tight.contains(.detail))
        #expect(!tight.contains(.inspector))
        #expect(tight.contains(.primary), "The list is never what goes")
    }

    /// The arithmetic the whole fault came down to: a column was being offered the window rather
    /// than what the window had left.
    @Test("A column is offered the window less what the others cannot give up")
    func roomAccountsForEveryVisibleColumn() {
        let layout = AppModule.notes.shellLayout
        let visible: Set<ModuleShellLayout.Column> = [.sidebar, .primary, .detail, .inspector]

        let forList = layout.room(
            for: .primary, inWindowOfWidth: 1400, sidebarWidth: sidebar, showing: visible
        )

        let others = sidebar + layout.detail.width.minimum + layout.inspector.width.minimum
        #expect(forList == 1400 - others)
        #expect(forList < 1400, "The list was being offered the whole window")
    }

    @Test("A column hidden from the shell takes no room from the rest")
    func hiddenColumnsCostNothing() {
        let layout = AppModule.notes.shellLayout

        let withInspector = layout.room(
            for: .primary,
            inWindowOfWidth: 1400,
            sidebarWidth: sidebar,
            showing: [.sidebar, .primary, .detail, .inspector]
        )
        let without = layout.room(
            for: .primary,
            inWindowOfWidth: 1400,
            sidebarWidth: sidebar,
            showing: [.sidebar, .primary, .detail]
        )

        #expect(without == withInspector + layout.inspector.width.minimum)
    }

    /// A column is never offered less than it needs, even in a window that cannot hold everything —
    /// dropping a column is the shell's answer to that, not squeezing one below its minimum.
    @Test("Room never falls below the column's own minimum")
    func roomNeverGoesBelowTheMinimum() {
        let layout = AppModule.records.shellLayout

        let room = layout.room(
            for: .detail,
            inWindowOfWidth: 400,
            sidebarWidth: sidebar,
            showing: [.sidebar, .primary, .detail, .inspector]
        )

        #expect(room == layout.detail.width.minimum)
    }

    /// Resolving against the room rather than the window is what actually changes the answer.
    @Test("A stored width is bounded by the room, not by the window")
    func storedWidthsRespectTheRoom() {
        let layout = AppModule.notes.shellLayout
        let visible: Set<ModuleShellLayout.Column> = [.sidebar, .primary, .detail]
        let room = layout.room(
            for: .detail, inWindowOfWidth: 1100, sidebarWidth: sidebar, showing: visible
        )

        // The user dragged the editor wide on a much larger display.
        let resolved = layout.detail.width.resolved(stored: 900, available: room)

        #expect(resolved <= room)
        #expect(resolved >= layout.detail.width.minimum)
        #expect(
            layout.detail.width.resolved(stored: 900, available: 1100) > resolved,
            "Resolving against the window is what let one column take the others' space"
        )
    }
}

/// What reaches the store, and — the point of the type — what does not.
///
/// `PaneDragDetector` can only compare two samples. Everything about *which* two it is shown lives
/// in the recorder, and that is where both faults were: a stream of widths acted on one frame at a
/// time, and a sidebar collapse recorded as if somebody had dragged the divider.
@MainActor
@Suite("Pane width recorder")
struct PaneWidthRecorderTests {
    /// The one that was making the window sluggish. Every frame of an animation used to reach the
    /// store, and every write invalidated the shell that produced the next frame.
    @Test("A stream of widths produces at most one answer")
    func samplesAreCoalesced() {
        let recorder = PaneWidthRecorder()
        var recorded: [(ModuleShellLayout.Column, CGFloat)] = []
        recorder.onDrag = { column, width, _ in recorded.append((column, width)) }

        // A baseline, then a drag through eight intermediate widths.
        recorder.sample(500, of: .primary, windowWidth: 1600)
        recorder.settleNow()

        for width in stride(from: CGFloat(510), through: 580, by: 10) {
            recorder.sample(width, of: .primary, windowWidth: 1600)
        }
        recorder.settleNow()

        #expect(recorded.count == 1, "A drag is one preference, not one per frame")
        #expect(recorded.first?.1 == 580, "The width that matters is the one it came to rest at")
    }

    /// Hiding the sidebar widens the pane beside it without the window changing size, which is
    /// exactly what the drag test cannot tell apart on its own. Left unsaid, collapsing the sidebar
    /// silently rewrote the module's stored width to whatever the animation happened to pass through.
    @Test("A width the shell caused is not stored")
    func shellMovesAreNotDrags() {
        let recorder = PaneWidthRecorder()
        var recorded: [CGFloat] = []
        recorder.onDrag = { _, width, _ in recorded.append(width) }

        recorder.sample(500, of: .primary, windowWidth: 1600)
        recorder.settleNow()

        recorder.expectShellMove(of: [.primary])
        recorder.sample(720, of: .primary, windowWidth: 1600)
        recorder.settleNow()

        #expect(recorded.isEmpty)
    }

    /// One warning covers one settle. Collapsing the sidebar must not stop the recorder listening
    /// for the rest of the session.
    @Test("A drag after the shell has settled is still a drag")
    func expectationDoesNotOutliveTheSettle() {
        let recorder = PaneWidthRecorder()
        var recorded: [CGFloat] = []
        recorder.onDrag = { _, width, _ in recorded.append(width) }

        recorder.sample(500, of: .primary, windowWidth: 1600)
        recorder.settleNow()
        recorder.expectShellMove(of: [.primary])
        recorder.sample(720, of: .primary, windowWidth: 1600)
        recorder.settleNow()

        recorder.sample(760, of: .primary, windowWidth: 1600)
        recorder.settleNow()

        #expect(recorded == [760])
    }

    /// The case that decides why an expectation expires at the settle rather than at the next
    /// sample: two modules whose policies agree move nothing, so no sample ever arrives, and an
    /// expectation left lying about would swallow the user's next drag instead.
    @Test("A shell move that moves nothing does not consume the next drag")
    func unmovedShellMoveIsForgotten() {
        let recorder = PaneWidthRecorder()
        var recorded: [CGFloat] = []
        recorder.onDrag = { _, width, _ in recorded.append(width) }

        recorder.sample(500, of: .primary, windowWidth: 1600)
        recorder.settleNow()

        recorder.expectShellMove(of: [.primary])
        recorder.settleNow() // Nothing moved, so nothing was sampled.

        recorder.sample(560, of: .primary, windowWidth: 1600)
        recorder.settleNow()

        #expect(recorded == [560])
    }

    @Test("A column the window resized is not a drag")
    func windowResizeIsNotADrag() {
        let recorder = PaneWidthRecorder()
        var recorded: [CGFloat] = []
        recorder.onDrag = { _, width, _ in recorded.append(width) }

        recorder.sample(500, of: .primary, windowWidth: 1600)
        recorder.settleNow()
        recorder.sample(560, of: .primary, windowWidth: 1720)
        recorder.settleNow()

        #expect(recorded.isEmpty)
    }

    @Test("Each column is judged on its own")
    func columnsAreIndependent() {
        let recorder = PaneWidthRecorder()
        var recorded: [ModuleShellLayout.Column] = []
        recorder.onDrag = { column, _, _ in recorded.append(column) }

        recorder.sample(500, of: .primary, windowWidth: 1600)
        recorder.sample(700, of: .detail, windowWidth: 1600)
        recorder.settleNow()

        recorder.expectShellMove(of: [.detail])
        recorder.sample(560, of: .primary, windowWidth: 1600)
        recorder.sample(760, of: .detail, windowWidth: 1600)
        recorder.settleNow()

        #expect(recorded == [.primary], "An expectation about one column must not cover the other")
    }
}

/// Three window sizes, walked deliberately.
///
/// ### Why this is a test rather than three screenshots
/// Because "does this still work at 900 points" is a question about arithmetic that is already pure
/// — see ``ElephruitDesign/ModuleShellLayout/widths(windowWidth:sidebarWidth:showsList:userWantsInspector:hasSelection:stored:)``
/// — and a screenshot answers it once, for one machine, at one text size, on the day it was taken.
/// The visual half of a layout review is still a visual review; this is the half that can be pinned
/// down, and it is the half that regressed.
@Suite("Narrow, standard, and very wide")
struct WindowSizeSweepTests {
    /// The app's own minimum, a laptop, and an ultrawide.
    private static let windows: [CGFloat] = [900, 1440, 2560]

    private let sidebar: CGFloat = 208

    /// The modules this sweep holds to the *content is widest* rule.
    ///
    /// Calendar and Time are canvases — their main content is the primary column — and People is the
    /// module the rule was written for. Tasks and Bookmarks currently come out the other way round
    /// at some widths, because the shell's "spare width goes to the list first" rule lets a list
    /// reach a ceiling above the detail pane's own ideal. That is the same shape of problem, in
    /// modules outside this pass; changing their declared widths is a decision about Tasks, not a
    /// consequence of a decision about People, so it is reported rather than made here.
    private static let contentFirstModules: [AppModule] = [.calendar, .time, .records]

    @Test("No module in this pass leaves its main content the narrowest column")
    func mainContentIsNeverTheNarrowest() {
        for module in Self.contentFirstModules {
            let layout = module.shellLayout

            for window in Self.windows {
                let result = layout.widths(
                    windowWidth: window,
                    sidebarWidth: sidebar,
                    userWantsInspector: true,
                    hasSelection: true
                )

                // The main content is the detail pane where a module has one, and the primary
                // column where the module *is* its primary column — a calendar, a tracker.
                let main = result.detail ?? result.primary

                if let inspector = result.inspector {
                    #expect(
                        main > inspector,
                        "\(module.title) at \(window): the inspector is wider than the content"
                    )
                }
                #expect(
                    main >= result.primary || result.detail == nil,
                    "\(module.title) at \(window): the list is wider than what it opens"
                )
            }
        }
    }

    @Test("Every column that is on screen is usable, at every size")
    func nothingIsSqueezedBelowItsMinimum() {
        for module in AppModule.displayOrder {
            let layout = module.shellLayout

            for window in Self.windows {
                let result = layout.widths(
                    windowWidth: window,
                    sidebarWidth: sidebar,
                    userWantsInspector: true,
                    hasSelection: true
                )

                #expect(result.primary >= layout.primary.minimum, "\(module.title) at \(window)")
                if let detail = result.detail {
                    #expect(detail >= layout.detail.width.minimum, "\(module.title) at \(window)")
                }
                if let inspector = result.inspector {
                    #expect(inspector >= layout.inspector.width.minimum, "\(module.title) at \(window)")
                }

                // And the columns fill the window rather than leaving a strip of nothing beside a
                // divider — the failure that is invisible until somebody has a very wide display.
                //
                // Within a couple of points, not exactly. The proportional-shrink branch rounds each
                // column down so that no column can be pushed over its share, and three columns
                // rounding down can leave the set one or two points short in a window tight enough
                // for the branch to run at all. That is a hairline, it predates this pass, and
                // asserting exactness here would be asserting an implementation detail of the
                // rounding rather than the property that matters.
                #expect(
                    window - result.total <= 2,
                    "\(module.title) at \(window) leaves \(window - result.total) points unfilled"
                )
                #expect(result.total <= window, "\(module.title) at \(window) overflows the window")
            }
        }
    }

    /// The complaint, at the size it was reported at and at the two either side.
    @Test("People gives the profile the room at every size")
    func peopleProportionsHold() {
        let layout = AppModule.records.shellLayout

        for window in Self.windows {
            let result = layout.widths(
                windowWidth: window,
                sidebarWidth: sidebar,
                userWantsInspector: true,
                hasSelection: true
            )

            let profile = result.detail ?? 0
            #expect(profile > result.primary, "the list out-measures the profile at \(window)")

            // At the narrowest the inspector must not be on screen at all: three columns and a
            // sidebar in 900 points would leave the profile unusable, and the module's threshold is
            // what prevents it rather than the arithmetic scraping through.
            if window <= 1_200 {
                #expect(result.inspector == nil, "the inspector appeared at \(window)")
            }
        }
    }

    /// A profile column with no ceiling has to be the thing that grows, and the growth has to land
    /// in margins rather than in a contact row eighteen hundred points wide.
    @Test("The profile column grows without the profile itself stretching")
    func theProfileCapsItsOwnMeasure() {
        let layout = AppModule.records.shellLayout
        let ultrawide = layout.widths(
            windowWidth: 2_560,
            sidebarWidth: sidebar,
            userWantsInspector: false,
            hasSelection: true
        )

        let column = ultrawide.detail ?? 0
        #expect(column > 1_500, "the profile column is not taking the spare width")
        #expect(
            PersonWorkspaceView.measure < column,
            "the profile has no measure to stop it stretching with its column"
        )
    }
}

/// The width arithmetic itself, with no modules involved.
@Suite("Pane width")
struct PaneWidthTests {
    @Test("Three numbers that disagree are normalised rather than trusted")
    func normalisation() {
        let inverted = PaneWidth(minimum: 400, ideal: 100, maximum: 200)

        #expect(inverted.minimum == 400)
        #expect(inverted.maximum == 400)
        #expect(inverted.ideal == 400)
    }

    @Test("Nothing stored means the ideal")
    func idealIsTheDefault() {
        let width = PaneWidth(minimum: 200, ideal: 400, maximum: 800)
        #expect(width.resolved(stored: nil, available: 2000) == 400)
    }

    @Test("An unbounded column may take whatever it is given")
    func unbounded() {
        let canvas = PaneWidth(minimum: 500, ideal: 1000)
        #expect(canvas.resolved(stored: 3000, available: 4000) == 3000)
    }

    @Test("Available space bounds the answer but the minimum bounds the space")
    func availabilityAndMinimum() {
        let width = PaneWidth(minimum: 400, ideal: 600, maximum: 900)

        #expect(width.resolved(stored: 800, available: 500) == 500)
        #expect(width.resolved(stored: 800, available: 100) == 400, "narrower than usable is not an answer")
    }

    @Test("A fixed column is fixed")
    func fixed() {
        let pinned = PaneWidth.fixed(320)

        #expect(pinned.isFixed)
        #expect(pinned.resolved(stored: 900, available: 2000) == 320)
    }

    @Test("A window that has not been measured yet does not force the minimum")
    func unmeasuredWindow() {
        let width = PaneWidth(minimum: 400, ideal: 600, maximum: 900)
        #expect(width.resolved(stored: 700, available: 0) == 700)
    }
}

/// Where the width goes when there is more window than the columns asked for.
///
/// The old rule gave every spare point to the detail column, which is how a 1710-point window ended
/// up laying the list out at 340 and putting 1,240 behind "Nothing selected" — titles truncating to
/// "Send Maya the dog trai…" with two thirds of the window empty beside them.
@Suite("Room to spare")
struct RoomToSpareTests {
    private func widths(
        _ layout: ModuleShellLayout,
        window: CGFloat,
        hasSelection: Bool = true
    ) -> ModuleShellLayout.Widths {
        layout.widths(
            windowWidth: window,
            sidebarWidth: 208,
            userWantsInspector: false,
            hasSelection: hasSelection
        )
    }

    @Test("A wide window fills the list to its own ceiling before anything else")
    func listReachesItsMaximum() {
        let layout = PrimaryNavigationLayout.shell
        let result = widths(layout, window: 1710)

        #expect(layout.primary.maximum == 520)
        #expect(result.primary == 520)
    }

    /// The bound that makes the change safe. A list is allowed to reach the number its module
    /// declared and not one point further, which is the difference between this and the unbounded
    /// column the previous rule was written against.
    @Test("It never exceeds the ceiling, however wide the window")
    func listNeverExceedsItsMaximum() {
        let layout = PrimaryNavigationLayout.shell
        for window in [1710, 2400, 3200, 6000].map(CGFloat.init) {
            #expect(widths(layout, window: window).primary == 520)
        }
    }

    /// Nothing may be left over. A column set that adds up to less than the window leaves a strip of
    /// nothing beside a divider, which reads as a rendering fault rather than as spare room.
    @Test("The columns account for the whole window", arguments: [1200, 1440, 1710, 2400])
    func nothingIsLeftUnallocated(window: Int) {
        let result = widths(PrimaryNavigationLayout.shell, window: CGFloat(window))
        #expect(result.total == CGFloat(window))
    }

    /// A canvas module has no detail column, so its primary column *is* the reading surface and
    /// still takes everything — the change is about which column is fed first, not about capping
    /// the one that was being fed.
    @Test("A canvas still takes the whole window")
    func canvasIsUnaffected() {
        let result = widths(AppModule.calendar.shellLayout, window: 1710)
        #expect(result.detail == nil)
        #expect(result.primary == CGFloat(1502))
    }

    /// A narrow window is untouched by any of this: there is no spare width, so the branch that
    /// shares it out never runs and every column sits at what it needs.
    @Test("A tight window still gives the list only its minimum")
    func tightWindowUnchanged() {
        let layout = PrimaryNavigationLayout.shell
        let result = widths(layout, window: 208 + layout.primary.minimum + layout.detail.width.minimum)
        #expect(result.primary == layout.primary.minimum)
    }
}

@Suite("Room to spare, per module")
struct RoomToSpareByModuleTests {
    /// Every document module whose detail pane has a ceiling, in a wide window, with nothing stored.
    /// Each should reach its own declared list ceiling — the number the module chose — rather than
    /// sitting at its ideal with the slack piled behind the detail pane.
    ///
    /// People is absent, and deliberately. The rule exists because *something* has to absorb the
    /// remainder when every column has a maximum, and a list growing to a bound it chose is better
    /// than a strip of nothing beside a divider. People's profile column has no maximum, so it
    /// absorbs the remainder by construction and the list has no reason to grow at all — which is
    /// the better answer, and the one `theProfileIsTheFlexibleColumn` holds instead.
    @Test(
        "Each document module fills its list to its own ceiling",
        // Neither Tasks nor Projects is here any more, and for the same reason: both stopped being
        // document modules with a list beside a detail column. A board of six columns does not fit
        // in the width a list gets, so there is no ceiling for it to fill.
        arguments: [AppModule.notes, .bookmarks, .archive, .trash]
    )
    func eachModuleReachesItsCeiling(module: AppModule) throws {
        let layout = module.shellLayout
        let result = layout.widths(
            windowWidth: 1710,
            sidebarWidth: 208,
            userWantsInspector: false,
            hasSelection: true
        )

        let ceiling = try #require(layout.primary.maximum)
        #expect(result.primary == ceiling)
        #expect(result.total == 1710)
    }
}

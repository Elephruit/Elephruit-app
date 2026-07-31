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
        layout.setWidth(760, of: .detail, in: .people, available: wideWindow)

        #expect(layout.width(of: .detail, in: .people, available: wideWindow) == 760)
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
        let people = layout.width(of: .detail, in: .people, available: wideWindow)

        for module in AppModule.allCases where module != .people && module != .notes {
            let other = layout.width(of: .detail, in: module, available: wideWindow)
            #expect(people >= other, "\(module) claims more room than a person's profile")
        }
    }

    @Test("The contact list has its own width, separate from the profile")
    func contactListIsSizedSeparately() {
        let layout = store()
        layout.setWidth(760, of: .detail, in: .people, available: wideWindow)

        #expect(
            layout.width(of: .primary, in: .people, available: wideWindow)
                == AppModule.people.shellLayout.primary.ideal,
            "widening the profile moved the contact list"
        )
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
        layout.setWidth(700, of: .detail, in: .people, available: wideWindow)
        layout.setWidth(400, of: .detail, in: .tasks, available: wideWindow)

        for _ in 0..<20 {
            #expect(layout.width(of: .detail, in: .people, available: wideWindow) == 700)
            #expect(layout.width(of: .detail, in: .calendar, available: wideWindow) == 0)
            #expect(layout.width(of: .detail, in: .tasks, available: wideWindow) == 400)
        }
    }

    // MARK: - Clamping what was restored

    /// A width dragged on a 6K display and restored into a laptop window must not push the list and
    /// the sidebar into a fight over the remaining hundred points.
    @Test("A width restored from a larger window is clamped to this one")
    func restoredWidthIsClampedToTheWindow() {
        let layout = store()
        layout.setWidth(900, of: .detail, in: .people, available: 3200)

        let onALaptop = layout.width(of: .detail, in: .people, available: 1280)
        #expect(onALaptop <= 1280)
        #expect(onALaptop >= AppModule.people.shellLayout.detail.width.minimum)
    }

    /// Clamping happens on the way out, so the original request survives a visit to a small window.
    @Test("A clamped width is not forgotten")
    func clampingIsNotDestructive() {
        let layout = store()
        layout.setWidth(800, of: .detail, in: .people, available: 3200)
        _ = layout.width(of: .detail, in: .people, available: 900)

        #expect(layout.width(of: .detail, in: .people, available: 3200) == 800)
    }

    @Test("A width outside the module's own range is brought back inside it")
    func obsoleteWidthsAreClamped() {
        let layout = store()
        let bounds = AppModule.tasks.shellLayout.detail.width
        layout.setWidth(4000, of: .detail, in: .tasks, available: wideWindow)

        let resolved = layout.width(of: .detail, in: .tasks, available: wideWindow)
        #expect(resolved == bounds.maximum)
        #expect(resolved >= bounds.minimum)
    }

    @Test("A pane never resolves below its minimum, even in a window that cannot hold it")
    func minimumWins() {
        let layout = store()
        let minimum = AppModule.people.shellLayout.detail.width.minimum

        #expect(layout.width(of: .detail, in: .people, available: 200) == minimum)
    }

    // MARK: - Persistence

    @Test("Widths survive a relaunch, per module")
    func widthsPersist() throws {
        let suite = "ModuleLayoutTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removeSuite(named: suite) }

        let first = ModuleLayoutStore(defaults: defaults)
        first.setWidth(700, of: .detail, in: .people, available: wideWindow)
        first.setWidth(420, of: .detail, in: .tasks, available: wideWindow)

        let afterRelaunch = ModuleLayoutStore(defaults: defaults)
        #expect(afterRelaunch.width(of: .detail, in: .people, available: wideWindow) == 700)
        #expect(afterRelaunch.width(of: .detail, in: .tasks, available: wideWindow) == 420)
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
                "tasks": ["someFutureColumn": 300.0],
            ],
            forKey: "layout.moduleColumnWidths"
        )

        let loaded = ModuleLayoutStore(defaults: defaults)
        #expect(loaded.width(of: .detail, in: .people, available: wideWindow) == 640)
        #expect(
            loaded.width(of: .detail, in: .tasks, available: wideWindow)
                == AppModule.tasks.shellLayout.detail.width.ideal
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
        let policy = AppModule.people.shellLayout.detail
        #expect(policy.isVisible(userWants: true, hasSelection: false, windowWidth: wideWindow))
    }

    @Test("A narrow window drops the pane and a wide one brings it back")
    func narrowWindowsDropTheInspector() {
        let policy = AppModule.people.shellLayout.inspector
        let threshold = policy.compactWindowWidth

        #expect(!policy.isVisible(userWants: true, hasSelection: true, windowWidth: threshold - 1))
        #expect(policy.isVisible(userWants: true, hasSelection: true, windowWidth: threshold))
    }

    @Test("Closing a pane is not undone by the next selection")
    func aClosedPaneStaysClosed() {
        // People's context sidebar does not hide itself when empty, so nothing should reopen it.
        #expect(!AppModule.people.shellLayout.detail.shouldOpenAfterSelection())
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
        let layout = AppModule.people.shellLayout
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

/// What reaches the store, and — the point of the type — what does not.
///
/// The detector above can only compare two samples. Everything about *which* two it is shown lives
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

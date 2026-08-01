import CoreGraphics
import Foundation
import Testing

@testable import ElephruitFeatures

/// Where the collapsed timer is allowed to be.
///
/// Every one of these is a fault somebody has actually had to look at: a pill that walked off the
/// screen, one that sat underneath the Dock, and one that shifted sideways every time the window
/// controls appeared. None of them is visible in a diff. All of them are the first thing you see if
/// you collapse the app, which is also the state in which this window is the only way back into it.
@Suite("Mini timer placement")
struct MiniTimerPlacementTests {
    /// A screen with a Dock along the bottom: 1512 × 982, menu bar off the top, Dock band off the
    /// bottom, origin at zero.
    private let placement = MiniTimerPlacement(
        area: CGRect(x: 0, y: 64, width: 1512, height: 880),
        dockOverhang: 32
    )

    private let opening: CGFloat = 24

    /// The rule the whole design rests on. Growing to show the window controls, shrinking to the
    /// bare clock, and a longer description are all the left edge moving — every control on the pill
    /// is against the right, and one that slid away as the panel resized would take itself out from
    /// under the pointer that arrived to press it.
    @Test("Changing width moves the left edge and only the left edge")
    func theRightEdgeHoldsStill() {
        let anchor = placement.defaultAnchor(openingInset: opening)

        let narrow = placement.frame(of: CGSize(width: 320, height: 64), hangingFrom: anchor)
        let wide = placement.frame(of: CGSize(width: 520, height: 64), hangingFrom: anchor)
        let narrowAgain = placement.frame(of: CGSize(width: 320, height: 64), hangingFrom: anchor)

        #expect(wide.maxX == narrow.maxX)
        #expect(narrowAgain.maxX == narrow.maxX)
        #expect(wide.minX < narrow.minX, "it should have grown leftwards")
        #expect(narrowAgain.minX == narrow.minX, "and come back to exactly where it started")
    }

    /// The bottom edge answers to the Dock as *drawn*, not as reserved. `visibleFrame` excludes the
    /// tile band and nothing else, and what the Dock puts on screen is a tray with padding, a
    /// rounded edge and a gap beneath it.
    @Test("It never sits under the Dock")
    func clearOfTheDock() {
        let anchor = CGPoint(x: 1400, y: placement.area.minY)

        let frame = placement.frame(of: CGSize(width: 320, height: 64), hangingFrom: anchor)

        #expect(frame.minY >= placement.area.minY + 32)
    }

    /// The regression this was written for. A panel measured taller than the screen used to be
    /// pushed *down* to fit — the top bound was applied last and won — so an oversized measurement
    /// sent the window off the bottom of the screen and underneath the Dock, which is the one place
    /// it is no use at all.
    @Test("A panel too tall for the screen is trimmed rather than pushed off the bottom")
    func anOversizeMeasurementCannotPushItOffScreen() {
        let anchor = placement.defaultAnchor(openingInset: opening)

        let size = placement.size(fitting: CGSize(width: 320, height: 10_000))
        let frame = placement.frame(of: size, hangingFrom: anchor)

        #expect(frame.minY >= placement.floor)
        #expect(frame.maxY <= placement.area.maxY)
        #expect(placement.area.contains(frame))
    }

    @Test("An anchor off the screen is pulled back onto it")
    func offScreenAnchorsAreRecovered() {
        let size = CGSize(width: 320, height: 64)

        let farRight = placement.frame(of: size, hangingFrom: CGPoint(x: 4000, y: 400))
        let farLeft = placement.frame(of: size, hangingFrom: CGPoint(x: -400, y: 400))
        let farBelow = placement.frame(of: size, hangingFrom: CGPoint(x: 1400, y: -900))
        let farAbove = placement.frame(of: size, hangingFrom: CGPoint(x: 1400, y: 5000))

        for frame in [farRight, farLeft, farBelow, farAbove] {
            #expect(placement.area.contains(frame), "\(frame) left the screen")
            #expect(frame.minY >= placement.floor)
        }
    }

    /// A measurement of nothing is a real state — a hosting view that has not been laid out reports
    /// zero — and a window sized to it is one nobody can see or click their way out of.
    @Test("Nothing measures to something you can still see")
    func floorsHold() {
        let size = placement.size(fitting: .zero)

        #expect(size.width == MiniTimerPlacement.minimumSize.width)
        #expect(size.height == MiniTimerPlacement.minimumSize.height)
    }

    @Test("It opens clear of the corner and of the Dock")
    func openingCorner() {
        let anchor = placement.defaultAnchor(openingInset: opening)

        #expect(anchor.x == placement.area.maxX - opening)
        #expect(anchor.y == placement.area.minY + opening + 32)

        let frame = placement.frame(of: CGSize(width: 320, height: 64), hangingFrom: anchor)
        #expect(placement.area.contains(frame))
    }

    /// A Dock down the side of the screen is not in this corner's way, so nothing is added for it —
    /// the overhang is only ever the bottom edge's problem.
    @Test("A Dock on the left costs the bottom edge nothing")
    func onlyTheBottomEdgePays() {
        let sideDock = MiniTimerPlacement(
            area: CGRect(x: 90, y: 0, width: 1422, height: 944),
            dockOverhang: 0
        )

        let anchor = sideDock.defaultAnchor(openingInset: opening)
        #expect(anchor.y == sideDock.area.minY + opening)

        let frame = sideDock.frame(of: CGSize(width: 320, height: 64), hangingFrom: anchor)
        #expect(sideDock.area.contains(frame))
    }
}

/// What the collapsed timer remembers between sittings.
@MainActor
@Suite("Mini timer preferences")
struct MiniTimerPreferenceTests {
    private func makeDefaults() throws -> UserDefaults {
        let name = "MiniTimerTests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    /// The point of collapsing the app to its clock is to keep the clock while working in something
    /// else. A timer that falls behind the window you switch to has failed at the one job it was
    /// left on screen for, and you find out it was still running when the day's total is wrong.
    @Test("It floats above other windows unless the user has said otherwise")
    func pinnedByDefault() throws {
        let defaults = try makeDefaults()
        let controller = MiniTimerController(services: .inMemory(populated: false), defaults: defaults)

        #expect(controller.isPinned)
    }

    /// Three states, not two: never chosen, chosen on, chosen off. Only the first takes the default,
    /// or changing that default would reach into the preferences of everybody who had already turned
    /// the thing off and turn it back on.
    @Test("Turning it off is remembered, and the default does not undo it")
    func turningItOffSticks() throws {
        let defaults = try makeDefaults()

        let first = MiniTimerController(services: .inMemory(populated: false), defaults: defaults)
        first.isPinned = false

        let second = MiniTimerController(services: .inMemory(populated: false), defaults: defaults)
        #expect(second.isPinned == false)
    }
}

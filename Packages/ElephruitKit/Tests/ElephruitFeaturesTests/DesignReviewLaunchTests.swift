import AppKit
import CoreGraphics
import Testing

@testable import ElephruitFeatures

/// How the design-review launch arguments are read.
///
/// Worth pinning down despite being a parser for a development-only flag, because the failure mode
/// is quiet in the worst way: an argument that is misread does not raise anything, it simply leaves
/// the app in the state it was already in — and a reviewer then photographs the wrong module, or
/// the wrong appearance, and believes they have checked something they have not.
@Suite("Design review launch arguments")
struct DesignReviewLaunchTests {
    // MARK: Reading a value

    @Test("A flag's value is the argument after it")
    func readsValue() {
        #expect(
            DesignReviewLaunch.value(for: "-A", in: ["-A", "people"]) == "people"
        )
    }

    @Test("A flag at the end of the list has no value")
    func trailingFlagHasNoValue() {
        #expect(DesignReviewLaunch.value(for: "-A", in: ["-A"]) == nil)
    }

    /// `-ElephruitStartModule -ElephruitAppearance dark` is a typo, not a request to open a module
    /// called "-ElephruitAppearance". Treating the next flag as a value would consume it, and the
    /// appearance would then be silently ignored too — one slip producing two wrong answers.
    @Test("A flag followed by another flag has no value")
    func flagFollowedByFlagHasNoValue() {
        #expect(DesignReviewLaunch.value(for: "-A", in: ["-A", "-B", "dark"]) == nil)
    }

    @Test("An absent flag has no value")
    func absentFlagHasNoValue() {
        #expect(DesignReviewLaunch.value(for: "-A", in: ["-B", "dark"]) == nil)
    }

    // MARK: Where to start

    @Test("A module name opens that module")
    func startsInAModule() {
        #expect(
            DesignReviewLaunch.start(in: ["-ElephruitStartModule", "people"])
                == .module(.records)
        )
    }

    /// The four destinations that belong to no module are named the same way the sidebar names
    /// them, so the argument reads as the thing wanted rather than as an implementation detail
    /// about which of the app's two navigation levels it lives on.
    @Test("The module-less destinations are reachable by their own names")
    func startsAtADestination() {
        #expect(
            DesignReviewLaunch.start(in: ["-ElephruitStartModule", "today"])
                == .destination(.today)
        )
        #expect(
            DesignReviewLaunch.start(in: ["-ElephruitStartModule", "home"])
                == .destination(.home)
        )
    }

    @Test("Case does not matter")
    func startIsCaseInsensitive() {
        #expect(
            DesignReviewLaunch.start(in: ["-ElephruitStartModule", "PeOpLe"])
                == .module(.records)
        )
    }

    /// A misspelled module leaves the window where it was rather than landing somewhere arbitrary.
    /// Falling back to a default would be worse than doing nothing: the reviewer would get a
    /// screenshot of a real module and no indication it was not the one they asked for.
    @Test("An unknown name changes nothing")
    func unknownStartIsIgnored() {
        #expect(DesignReviewLaunch.start(in: ["-ElephruitStartModule", "penguins"]) == nil)
        #expect(DesignReviewLaunch.start(in: []) == nil)
    }

    // MARK: Appearance

    @Test("All four appearances are nameable")
    func readsAppearance() {
        #expect(
            DesignReviewLaunch.appearanceName(in: ["-ElephruitAppearance", "dark"]) == .darkAqua
        )
        #expect(
            DesignReviewLaunch.appearanceName(in: ["-ElephruitAppearance", "light"]) == .aqua
        )
        #expect(
            DesignReviewLaunch.appearanceName(in: ["-ElephruitAppearance", "light-contrast"])
                == .accessibilityHighContrastAqua
        )
        #expect(
            DesignReviewLaunch.appearanceName(in: ["-ElephruitAppearance", "dark-contrast"])
                == .accessibilityHighContrastDarkAqua
        )
    }

    @Test("An unknown appearance leaves the system's in force")
    func unknownAppearanceIsIgnored() {
        #expect(DesignReviewLaunch.appearanceName(in: ["-ElephruitAppearance", "sepia"]) == nil)
        #expect(DesignReviewLaunch.appearanceName(in: []) == nil)
    }

    // MARK: Window size

    @Test("A size is width by height, in points")
    func readsWindowSize() {
        #expect(
            DesignReviewLaunch.windowSize(in: ["-ElephruitWindowSize", "1180x760"])
                == CGSize(width: 1180, height: 760)
        )
    }

    @Test("The separator is not case-sensitive")
    func windowSizeAcceptsCapitalX() {
        #expect(
            DesignReviewLaunch.windowSize(in: ["-ElephruitWindowSize", "900X520"])
                == CGSize(width: 900, height: 520)
        )
    }

    /// A window cannot be zero or negative points wide, and a size that parses to one would be
    /// applied — collapsing the window rather than resizing it.
    @Test("Unreadable and impossible sizes are refused")
    func refusesBadWindowSizes() {
        #expect(DesignReviewLaunch.windowSize(in: ["-ElephruitWindowSize", "wide"]) == nil)
        #expect(DesignReviewLaunch.windowSize(in: ["-ElephruitWindowSize", "1180"]) == nil)
        #expect(DesignReviewLaunch.windowSize(in: ["-ElephruitWindowSize", "0x760"]) == nil)
        #expect(DesignReviewLaunch.windowSize(in: ["-ElephruitWindowSize", "-100x760"]) == nil)
        #expect(DesignReviewLaunch.windowSize(in: ["-ElephruitWindowSize", "1180x0"]) == nil)
    }
}

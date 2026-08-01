import AppKit
import ElephruitCore
import SwiftUI

/// The whole app, collapsed to the clock.
///
/// ### What this is for
/// Somebody tracking time is, by definition, doing something else. The floating widget answers *is
/// it still going* while Elephruit is the window you are looking at; this answers it while it is
/// not. Collapsing puts away nine hundred points of library you are not reading and keeps the one
/// thing you are.
///
/// ### Why a panel rather than shrinking the window
/// Because a resized window is still a window: it keeps a title bar, a place in the window menu, and
/// a size somebody has to restore by hand afterwards. A panel is a different object with a different
/// job, and expanding puts the real window back exactly as it was — which is the property that makes
/// collapsing feel free rather than like a thing to undo.
///
/// It follows ``QuickJotPanel`` deliberately, including `.nonactivatingPanel`: pressing Pause on a
/// floating clock should not make Elephruit the frontmost application and take you away from
/// whatever you were doing.
final class MiniTimerPanel: NSPanel {
    init(content: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // Dragged from anywhere on it, because there is no title bar to grab and a window you cannot
        // move is one that will eventually be over the thing you need to read.
        isMovableByWindowBackground = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        // ### Why the window casts no shadow
        // Because the card inside it already does, and AppKit draws a window's shadow around the
        // window's *rectangle* — not around the rounded card sitting in it. With a clear background
        // that produced a grey box hanging below and behind the pill, which is what it looked like:
        // a shadow of something that is not there.
        hasShadow = false

        // The traffic lights would be three more things to look at on a surface whose whole point is
        // that there is one thing to look at. Closing is Expand; there is no other way to lose it.
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        contentView = content
    }

    /// Whether it stays above other applications' windows.
    ///
    /// Two separate settings, and both are needed. `level` decides whether it floats over other
    /// *apps*; the collection behaviour decides whether it follows you to another Space and sits
    /// over a full-screen window. Somebody who pins a timer and then goes full-screen in an editor
    /// meant both.
    var isPinned: Bool = false {
        didSet {
            level = isPinned ? .floating : .normal
            collectionBehavior = isPinned
                ? [.canJoinAllSpaces, .fullScreenAuxiliary]
                : [.managed, .fullScreenAuxiliary]
        }
    }

    // Key, so the buttons on it can be clicked; never main, so it does not pretend to be the app's
    // principal window while the real one is only hidden.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Where the collapsed timer goes: a pure function of where it is pinned, how big it wants to be,
/// and the screen it is on.
///
/// ### Why this is not simply four lines inside the controller
/// It was, and the four lines were wrong in a way nobody could see by reading them. The failures
/// this arithmetic produces are a window off the edge of the screen, a window underneath the Dock,
/// and a window that has walked away from the corner it was left in — none of which is visible in
/// a diff, all of which are obvious and infuriating to whoever it happens to. Pulled out here, the
/// rules can be *asserted*: see `MiniTimerPlacementTests`, which states each of them once.
struct MiniTimerPlacement: Hashable {
    /// The room the panel may use: the screen minus the menu bar and the Dock's reserved band.
    var area: CGRect

    /// How far above that reserved band the Dock is actually drawn.
    /// See ``MiniTimerController/dockOverhang(on:)``.
    var dockOverhang: CGFloat

    /// The least the panel will ever sit from an edge, however it got there.
    ///
    /// Smaller than the margin it opens at, on purpose: opening in the corner is a matter of taste,
    /// and being reachable is not — so a panel dragged near an edge is left where it was put rather
    /// than nudged back to the opening margin.
    static let minimumInset: CGFloat = 8

    /// Floors, so a measurement of nothing cannot produce a window nobody can see.
    ///
    /// Not hypothetical: an earlier version sized the panel from a hosting view that had never been
    /// laid out, whose answer is **zero**, and collapsing the app left an invisible window behind
    /// with no way back into it except the menu.
    static let minimumSize = CGSize(width: 200, height: 48)

    /// The lowest the bottom edge may sit: clear of the Dock as drawn, not merely as reserved.
    var floor: CGFloat {
        area.minY + Self.minimumInset + dockOverhang
    }

    /// The size the panel may actually be, given the room there is between that floor and the edges.
    ///
    /// Bounded so that a long description cannot produce a panel with a side nobody can reach.
    ///
    /// ### Why it rounds up, and why a third of a point matters
    /// Because what is being sized is a *window*, and a window is whole points on the screen whatever
    /// it is asked for. What is being fitted into it is text, whose line heights are fractional
    /// almost always — a row wanting 40.33 points in a window that ends up 40 is a third of a point
    /// short, and the thing living in that third of a point is the card's one-point border.
    ///
    /// So the bottom edge of the pill simply was not drawn: not missing, not mis-coloured, *cut off*,
    /// which is a much stranger thing to look at than a window obviously too small. Rounding up is
    /// the whole fix, and it costs at most one point of window nobody can see.
    func size(fitting wanted: CGSize) -> CGSize {
        CGSize(
            width: min(max(wanted.width.rounded(.up), Self.minimumSize.width), area.width - 2 * Self.minimumInset),
            height: min(max(wanted.height.rounded(.up), Self.minimumSize.height), area.maxY - Self.minimumInset - floor)
        )
    }

    /// Where a panel of this size hangs from this anchor.
    ///
    /// The anchor is the **bottom-right** corner, so the origin is derived from it and the size: a
    /// width that changes moves the left edge and can move nothing else. That is the whole rule this
    /// window has to keep, because every control on it is against the right and a surface that walks
    /// its own buttons out from under an arriving pointer is worse than one that cannot resize.
    ///
    /// The floor has the last word over the ceiling. A clamp that let the top bound win could push
    /// the panel back underneath the very thing this calculation exists to clear — which is what the
    /// previous one did whenever the panel was measured taller than it really was.
    func frame(of size: CGSize, hangingFrom anchor: CGPoint) -> CGRect {
        var origin = CGPoint(x: anchor.x - size.width, y: anchor.y)

        origin.x = min(origin.x, area.maxX - size.width - Self.minimumInset)
        origin.x = max(origin.x, area.minX + Self.minimumInset)

        let ceiling = max(floor, area.maxY - size.height - Self.minimumInset)
        origin.y = min(max(origin.y, floor), ceiling)

        return CGRect(origin: origin, size: size)
    }

    /// Where it hangs from the first time: the lower right, clear of the corner and the Dock.
    ///
    /// Only the first time. After that the panel remembers where it was dragged to, because a window
    /// that jumps back to a corner every time it opens is one nobody bothers moving.
    func defaultAnchor(openingInset: CGFloat) -> CGPoint {
        CGPoint(x: area.maxX - openingInset, y: area.minY + openingInset + dockOverhang)
    }
}

/// Owns the mini panel, and the fact of being collapsed.
///
/// ### Why the controller rather than the view holds "collapsed"
/// Because the view inside the panel is destroyed and rebuilt every time the panel opens, and the
/// question *is this app collapsed* has to outlive that. It is also read by the main window, which
/// cannot see inside a panel at all.
@MainActor
@Observable
public final class MiniTimerController {
    public private(set) var isCollapsed = false

    /// Whether the panel stays above other applications.
    ///
    /// **On unless the user says otherwise.** The whole reason to collapse the app to its clock is
    /// to keep the clock while you work in something else, and a timer that disappears behind the
    /// window you switch to has failed at the one thing it was left on screen to do — you find out
    /// it is still running when the day's total is wrong. Off by default made every person who
    /// wanted the obvious behaviour discover a toggle first.
    ///
    /// Remembered across collapses — somebody who wants it on top wants it on top every time, and
    /// making them say so twice is the kind of small forgetting that makes a feature feel unfinished.
    public var isPinned: Bool {
        didSet {
            panel?.isPinned = isPinned
            defaults.set(isPinned, forKey: Self.pinnedKey)
        }
    }

    /// Whether the panel is stripped back to the clock and its buttons.
    ///
    /// ### Why this is a third size and not the only small one
    /// Showing what you are working on is most of the value — a clock alone tells you time is
    /// passing, not what it is being spent on. But a description runs to whatever length somebody
    /// typed, and a panel that is three hundred points wide because of a sentence you already know
    /// is in the way. So the name is the default and this is the opt-out, remembered like the pin.
    /// Nothing resizes the panel from here. The view is about to lay itself out at a different
    /// width, and it will say so — which is the only account of the size this object trusts.
    public var isCompact: Bool {
        didSet {
            defaults.set(isCompact, forKey: Self.compactKey)
        }
    }

    private static let pinnedKey = "time.miniTimer.pinned"
    private static let compactKey = "time.miniTimer.compact"

    private var panel: MiniTimerPanel?

    /// The corner the panel hangs from: its **bottom-right**, in screen coordinates.
    ///
    /// ### Why the position is held rather than read back off the window
    /// Because the rule for this panel is that its right edge does not move. Gaining the window
    /// controls, losing the description, a longer thing being timed — all of them are changes to the
    /// left edge and to nothing else. Every control on the pill is against the right, and a surface
    /// that walks its own buttons out from under the pointer that arrived to press one is worse than
    /// one that cannot resize at all.
    ///
    /// Deriving that edge from `panel.frame` at the moment of each resize is what this replaces, and
    /// it is why the panel drifted: the frame is whatever the last resize left behind, so one
    /// placement made against a stale measurement became the anchor for the next, and the error
    /// accumulated across every widening and narrowing until the panel had walked off the screen.
    /// An anchor cannot accumulate error, because nothing computes it — it is set once, moved only
    /// when the user moves the window, and every size is fitted to it.
    private var anchor: NSPoint?

    /// The size the view last measured itself at. See ``contentSizeChanged(to:)``.
    ///
    /// Held so the panel can be re-placed without waiting for the contents to change shape again —
    /// on a different screen, or after the Dock has moved.
    private var contentSize: NSSize?

    /// The frame this object last sent the panel to, so a move notification can tell a drag from its
    /// own work.
    private var placedFrame: NSRect?

    private var moveObserver: (any NSObjectProtocol)?

    private let services: AppServices
    private let defaults: UserDefaults

    /// The windows hidden on the way in, so exactly those come back.
    ///
    /// Held rather than re-derived, because "every window that was visible" is not the same set a
    /// minute later — and putting back a window the user had already closed would be the app
    /// deciding it knows better.
    private var hiddenWindows: [NSWindow] = []

    public init(services: AppServices, defaults: UserDefaults = .standard) {
        self.services = services
        self.defaults = defaults
        // `object(forKey:)` rather than `bool(forKey:)`, because those are three states and not two:
        // never chosen, chosen on, chosen off. Only the first defaults to pinned — somebody who
        // deliberately turned it off must not have it turned back on by a change of default.
        self.isPinned = defaults.object(forKey: Self.pinnedKey) as? Bool ?? true
        self.isCompact = defaults.bool(forKey: Self.compactKey)
    }

    /// Puts the app away and leaves the clock.
    public func collapse() {
        guard !isCollapsed else { return }

        show()

        // Ordered out rather than closed: closing a document window is a decision about the user's
        // work, and this is a decision about screen space. Everything is exactly where it was.
        hiddenWindows = NSApp.windows.filter { window in
            window !== panel && window.isVisible && window.canBecomeMain
        }
        hiddenWindows.forEach { $0.orderOut(nil) }

        isCollapsed = true
    }

    /// Brings the app back and puts the clock away.
    public func expand() {
        hiddenWindows.forEach { $0.makeKeyAndOrderFront(nil) }
        hiddenWindows = []

        panel?.orderOut(nil)
        isCollapsed = false
        NSApp.activate()
    }

    /// Shows the panel without hiding anything — for a preview, or a second collapse.
    private func show() {
        if let panel {
            panel.isPinned = isPinned
            // Re-placed on every appearance rather than only when the panel is built. A remembered
            // position is a convenience and not a promise: the screen it was last on may be gone,
            // may be a different size, or may have grown a Dock along the edge it was sitting over.
            // Opening somewhere the user cannot reach it is the one failure this window cannot
            // recover from, because it *is* the way back into the app.
            place()
            panel.orderFront(nil)
            return
        }

        let hosting = NSHostingView(
            rootView: MiniTimerView(controller: self).appServices(services)
        )
        hosting.sizingOptions = [.preferredContentSize]

        // ### Why the safe area has to be turned off, and what it cost to find out
        // A `.titled` window has a title bar whether or not you can see one. This panel's is hidden
        // and transparent and the content view is told to fill the frame — but AppKit still reports
        // a **24-point top safe-area inset**, because the ordinary reason to draw under a title bar
        // is to put something decorative there, not to pretend it does not exist.
        //
        // SwiftUI honours that inset, so the card was laid out below an invisible title bar and its
        // bottom ran off the end of a window sized to hold it exactly. What that looked like was a
        // pill with no bottom edge: the fill was there, the border was not, because the border was
        // the part hanging outside the window.
        //
        // It is worth saying how this was finally established, because two rounds of reading the
        // code did not: the view was rendered into a bitmap with `cacheDisplay(in:to:)` and the rows
        // counted. The card's top border was at 20 points in a window whose padding is 8, and
        // everything below 58 was gone. Nothing about a layout that reads correctly will tell you
        // that; the pixels will.
        hosting.safeAreaRegions = []

        let panel = MiniTimerPanel(content: hosting)
        panel.isPinned = isPinned
        self.panel = panel

        observeMovement(of: panel)
        place()
        panel.orderFront(nil)
    }

    // MARK: - Where it sits

    /// Puts the panel where the anchor says, at the size the contents last measured.
    ///
    /// Everything hangs off the anchor, which is why the right edge holds still: the origin is
    /// *derived* from it and the width, so a width that changes moves the left edge and can move
    /// nothing else. Nothing here reads the current frame and computes a new one from it, which is
    /// what used to let one bad measurement become the starting point for every placement after it.
    ///
    /// The arithmetic itself is in ``MiniTimerPlacement``, where it can be asserted.
    ///
    private func place() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }

        let placement = MiniTimerPlacement(
            area: screen.visibleFrame,
            dockOverhang: Self.dockOverhang(on: screen)
        )

        let content = placement.size(fitting: contentSize ?? Self.placeholderSize)
        let frameSize = panel.frameRect(forContentRect: CGRect(origin: .zero, size: content)).size
        let frame = placement.frame(
            of: frameSize,
            hangingFrom: anchor ?? placement.defaultAnchor(openingInset: Self.edgeInset)
        )

        // Whatever the clamp had to do is now where the panel lives, so the anchor is brought into
        // line with it — before the early return, so that a placement which changed nothing still
        // records where the panel is. Without this, a panel pulled back on screen would spring to
        // its old corner the next time its contents changed shape, which is a panel that fights
        // being moved.
        anchor = CGPoint(x: frame.maxX, y: frame.minY)

        // Compared against where it was last *sent* rather than where it is now, so a resize that
        // arrives mid-animation does not restart the animation it is already running.
        guard frame != placedFrame else { return }
        placedFrame = frame

        // In one step, always. Nothing about this window moves gradually — the sliding is the card's
        // job, and ``contentSizeChanged(to:)`` says why it has to be.
        panel.setFrame(frame, display: true)
    }

    /// Read from the workspace rather than the SwiftUI environment, because this is a window being
    /// moved rather than a view being drawn — and the setting means the same thing to both.
    private static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Follows the window when the user drags it, and only then.
    ///
    /// The anchor is the whole of this panel's position, so something has to write to it when the
    /// person moves the window by hand — otherwise the next change of shape would yank the pill back
    /// to wherever it was last placed, which reads as the app refusing to be put somewhere.
    ///
    /// Frames this object set are ignored by comparison rather than by a flag, because the move
    /// notification is not guaranteed to arrive inside the call that caused it, and a flag that has
    /// already been cleared by then would let the panel treat its own placement as a drag.
    private func observeMovement(of panel: MiniTimerPanel) {
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.frame != self.placedFrame else { return }
                self.anchor = NSPoint(x: panel.frame.maxX, y: panel.frame.minY)
            }
        }
    }


    /// How far above its own reserved band the Dock's tray is actually drawn.
    ///
    /// ### Why `visibleFrame` turned out not to be enough
    /// `visibleFrame` is a *layout* promise — the rectangle the system will not zoom a window past —
    /// and the Dock reserves its tile band there and no more. What it *draws* is a floating tray, and
    /// the tray's padding, its rounded edge, and the gap it leaves from the bottom of the screen all
    /// stand in space the screen still calls visible. So a panel opened a respectable margin above
    /// `visibleFrame.minY` opened underneath the Dock, which is the one place the one window meant to
    /// stay in sight is no use at all.
    ///
    /// ### Why a constant, and why only along the bottom
    /// The overhang is chrome rather than content: it is the same handful of points whether the icons
    /// are set small or large, so scaling it against the reserved band would only make a large Dock
    /// push the panel into the middle of the screen. And it is added only when the Dock is along the
    /// bottom edge — the one this corner shares with it — which is what comparing the three insets
    /// establishes without asking the Dock anything the sandbox will not answer.
    static func dockOverhang(on screen: NSScreen) -> CGFloat {
        let bottom = screen.visibleFrame.minY - screen.frame.minY
        let left = screen.visibleFrame.minX - screen.frame.minX
        let right = screen.frame.maxX - screen.visibleFrame.maxX

        guard bottom > left, bottom > right else { return 0 }
        return Self.dockGlassOverhang
    }

    /// The margin the panel keeps from the edges of the screen when it first opens.
    private static let edgeInset: CGFloat = 24

    /// What the panel is sized to before the view has measured itself.
    ///
    /// On screen only for the frame between the window appearing and SwiftUI laying its contents
    /// out. It is a placeholder rather than a guess anybody relies on: the anchor puts its right
    /// edge exactly where the real one will be, so the correction that follows moves the left edge
    /// and nothing else.
    private static let placeholderSize = NSSize(width: 320, height: 64)

    /// See ``dockOverhang(on:)``.
    ///
    /// Measured against a Dock reserving 64 points and drawing something closer to a hundred: the
    /// tray's own gap from the bottom of the screen, the padding around the tiles, and the row the
    /// running-app dots sit in. Erring high costs a panel that opens a little further off the corner
    /// than it strictly had to; erring low costs the whole point of the panel.
    private static let dockGlassOverhang: CGFloat = 32

    /// Told by the view how big it has laid itself out to be.
    ///
    /// ### Why the view says, rather than the panel asking
    /// Because asking was wrong, twice, in the same way both times. `NSHostingView.fittingSize` is
    /// SwiftUI answering *how big would you like to be*, and that answer is only true once it has
    /// laid the new contents out. Asking during the update that changed them — which is exactly when
    /// a panel sized by hand wants to ask — returns the size of what was there before, so the window
    /// was set to the width of a pill without the controls it had just gained.
    ///
    /// What that looks like is worth writing down, because it does not look like a sizing bug. The
    /// root of this view is `.fixedSize()`, so contents too big for the window are not compressed
    /// into it: they overflow and are clipped **centred**. The whole pill therefore appears to jump
    /// sideways by half the missing width and lose an end, which reads as the panel moving rather
    /// than as the window being too small — and the wrong frame it left behind then became the
    /// starting point for the next placement.
    ///
    /// A `GeometryReader` behind the card measures what SwiftUI actually laid out, at the moment it
    /// laid it out, and reports every intermediate size along an animation. So the window follows
    /// its contents frame by frame rather than guessing once: the left edge slides out as the
    /// controls appear, which *is* the animation, and nothing anywhere has to be timed.
    public func contentSizeChanged(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let isFirst = contentSize == nil
        contentSize = size

        // ### Why growing happens now and shrinking waits to be told
        // The card slides; the window does not. A window that grows while something opens inside it
        // uncovers, on every frame, a strip of itself it has not drawn — and only growing does that,
        // which is why closing the menu was smooth and opening it stuttered, and why nothing about
        // reading the code suggested the two were different at all.
        //
        // So the room is made **before** the card needs it and taken away **after** it has stopped
        // wanting it. Growing goes through immediately: the card is still its old size, so the strip
        // that appears is transparent, uncovered once rather than ten times, and nothing is drawn
        // into it until the slide arrives. Shrinking waits for ``contentSettled()``, because a
        // window that closed in first would crop the card while it was still moving.
        guard isFirst || Self.prefersReducedMotion || grows(to: size, from: panel) else { return }
        place()
    }

    /// Told when the card has finished moving, so the window can give back room it no longer needs.
    ///
    /// ### Why this is a message rather than a delay
    /// It was a delay: a quarter of a second, chosen to outlast a slide of eighteen hundredths. A
    /// guessed interval is wrong in both directions. Too short crops the card while it is still
    /// moving; too long, or cancelled by one of the size reports the running clock produces as its
    /// digits change width, leaves the window standing open around a card that has already closed —
    /// a drawer that will not shut, which is exactly what it looked like.
    ///
    /// The card knows when it has stopped. Nothing else has to.
    public func contentSettled() {
        place()
    }

    /// Whether this size needs more room than the window currently has, in either direction.
    ///
    /// Either direction, because the cost of being wrong one way is a strip of empty window nobody
    /// can see, and the cost of being wrong the other is the card cut off while it moves.
    private func grows(to size: CGSize, from panel: MiniTimerPanel?) -> Bool {
        guard let panel else { return true }
        let current = panel.contentRect(forFrameRect: panel.frame).size
        return size.width > current.width || size.height > current.height
    }

    /// Closes the panel and forgets it, for window teardown and tests.
    public func shutDown() {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil

        panel?.orderOut(nil)
        panel = nil
        placedFrame = nil
        hiddenWindows = []
        isCollapsed = false
    }
}

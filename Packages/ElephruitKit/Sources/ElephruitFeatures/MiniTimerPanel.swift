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
    public var isCompact: Bool {
        didSet {
            defaults.set(isCompact, forKey: Self.compactKey)
            resizeToFit()
        }
    }

    private static let pinnedKey = "time.miniTimer.pinned"
    private static let compactKey = "time.miniTimer.compact"

    private var panel: MiniTimerPanel?

    /// Kept so the panel can be resized when the contents change shape.
    ///
    /// A window does not follow its SwiftUI contents on its own once its size has been set by hand,
    /// and toggling compact changes the width by about a hundred and eighty points.
    private var hosting: NSView?
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
        self.isPinned = defaults.bool(forKey: Self.pinnedKey)
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
            panel.orderFront(nil)
            return
        }

        let hosting = NSHostingView(
            rootView: MiniTimerView(controller: self).appServices(services)
        )
        hosting.sizingOptions = [.preferredContentSize]

        let panel = MiniTimerPanel(content: hosting)
        panel.isPinned = isPinned

        self.hosting = hosting
        self.panel = panel

        sizeToFit(panel)
        positionInLowerRight(panel)

        panel.orderFront(nil)

        // ### Why it is sized twice
        // SwiftUI has not finished deciding how wide it wants to be at the moment the panel is
        // built: `fittingSize` after one layout pass is an underestimate, and the window then grows
        // to fit *after* it has been positioned — rightwards, off the edge of the screen, taking
        // every control but the first with it. One turn of the run loop later the answer is settled,
        // and re-fitting against the right edge puts it back where it belongs.
        DispatchQueue.main.async { [weak self] in self?.resizeToFit() }
    }

    /// Makes the panel exactly as big as its contents want to be.
    ///
    /// ### Why the layout pass is not optional
    /// `fittingSize` on a hosting view that has never been laid out is **zero**, and a panel set to
    /// zero is a panel nobody can see — which is exactly what happened: collapsing hid the app and
    /// left an invisible window behind, with no way back except the menu. The floor is belt and
    /// braces for the same failure arriving another way.
    private func sizeToFit(_ panel: MiniTimerPanel) {
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()

        let wanted = hosting.fittingSize
        panel.setContentSize(
            NSSize(
                width: max(wanted.width, 200),
                height: max(wanted.height, 48)
            )
        )
    }

    /// Re-sizes in place, keeping the panel's right edge where it was.
    ///
    /// Anchored on the right because that is the edge the clock and the buttons are against, and a
    /// panel that grew leftwards from a fixed left edge would walk its own controls out from under
    /// the pointer that just pressed one.
    private func resizeToFit() {
        guard let panel else { return }
        let right = panel.frame.maxX
        let bottom = panel.frame.minY

        sizeToFit(panel)
        panel.setFrameOrigin(NSPoint(x: right - panel.frame.width, y: bottom))
        clampOnScreen(panel)
    }

    /// Drags the panel back inside the screen if it has grown past an edge.
    ///
    /// Growing is the case that matters — a panel widened by a long description or by leaving
    /// compact mode extends to the *right*, which is where the screen ends and where every one of
    /// its buttons lives.
    private func clampOnScreen(_ panel: NSPanel) {
        guard let area = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let inset: CGFloat = 8

        var origin = panel.frame.origin
        origin.x = min(origin.x, area.maxX - panel.frame.width - inset)
        origin.x = max(origin.x, area.minX + inset)
        origin.y = max(origin.y, area.minY + inset)
        origin.y = min(origin.y, area.maxY - panel.frame.height - inset)

        panel.setFrameOrigin(origin)
    }

    /// Opens where the widget it replaces was: the lower-right of the screen it is on.
    ///
    /// Only the first time. After that the panel remembers where it was dragged to, because a window
    /// that jumps back to a corner every time it opens is one nobody bothers moving.
    private func positionInLowerRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }

        // `visibleFrame` rather than `frame`, so the Dock and the menu bar are already excluded.
        // Using the full frame put the panel behind the Dock, where half of it was unreachable.
        let area = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: area.maxX - panel.frame.width - Self.edgeInset,
                y: area.minY + Self.edgeInset + dockOverhang(on: screen)
            )
        )
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
    private func dockOverhang(on screen: NSScreen) -> CGFloat {
        let bottom = screen.visibleFrame.minY - screen.frame.minY
        let left = screen.visibleFrame.minX - screen.frame.minX
        let right = screen.frame.maxX - screen.visibleFrame.maxX

        guard bottom > left, bottom > right else { return 0 }
        return Self.dockGlassOverhang
    }

    /// The margin the panel keeps from the edges of the screen when it first opens.
    private static let edgeInset: CGFloat = 24

    /// See ``dockOverhang(on:)``.
    ///
    /// Measured against a Dock reserving 64 points and drawing something closer to a hundred: the
    /// tray's own gap from the bottom of the screen, the padding around the tiles, and the row the
    /// running-app dots sit in. Erring high costs a panel that opens a little further off the corner
    /// than it strictly had to; erring low costs the whole point of the panel.
    private static let dockGlassOverhang: CGFloat = 32

    /// Re-fits the panel to contents that have changed shape.
    ///
    /// Called by the view when its hover state changes, because the window controls appear and
    /// disappear rather than sitting there invisibly reserving room — which on a panel this small is
    /// the difference between a tidy pill and a pill with a hole in it.
    ///
    /// ### Why it fits twice, the second time a turn later
    /// This is the same failure `show()` documents, arriving by the other door, and it was worse
    /// here because nothing came along afterwards to correct it. `fittingSize` asks SwiftUI how big
    /// it wants to be, and asking *during the update that changed what is in it* gets the answer for
    /// what was in it before: the controls had not been laid out yet, so the panel was set to the
    /// width of a pill that did not have them.
    ///
    /// What that looked like is worth recording, because it does not look like a sizing bug. The
    /// root of this view is `.fixedSize()`, so contents too big for the window are not compressed —
    /// they overflow it and are clipped, **centred**. So the whole pill appeared to jump leftwards
    /// by half the missing width and lose its right-hand end, which reads as the panel moving rather
    /// than as the window being too small. One turn later the answer is settled, and because both
    /// fits anchor the right edge the correction is invisible: the panel grows leftwards, which is
    /// the direction it has to grow, since every control the pointer is on the way to is on the
    /// right.
    public func contentSizeChanged() {
        resizeToFit()
        DispatchQueue.main.async { [weak self] in self?.resizeToFit() }
    }

    /// Closes the panel and forgets it, for window teardown and tests.
    public func shutDown() {
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        hiddenWindows = []
        isCollapsed = false
    }
}

import XCTest

extension XCUIElement {
    /// Taps the middle of this element, as a coordinate.
    ///
    /// For the shell's floating controls — the plus and the fan it opens — this is the only
    /// reliable way to press them, and the difference is not cosmetic.
    ///
    /// `XCUIElement.tap()` does not simply tap the middle of the frame it reports. On most
    /// screens the distinction never shows: the plus reports the right frame, says it is
    /// hittable, and a plain `tap()` opens the fan. On Reminders it does not — the whole
    /// background of that screen is one large "new reminder" tap target sitting behind the
    /// button, and a plain `tap()` on the plus lands on *it*, so the assertion that the fan
    /// opened fails against a screen that has quietly opened a reminder composer instead.
    ///
    /// The same tap aimed as a coordinate — this — hits the plus every time, on every screen.
    /// So the control is not at fault and neither is a finger, which is the case this stands in
    /// for: what is unreliable is `tap()`'s own choice of point when something large and
    /// tappable lies underneath. Anything reaching for the plus or one of its five choices
    /// should come through here rather than discover that again.
    func tapCenter() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}

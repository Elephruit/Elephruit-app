import AppKit
import ElephruitCore
import SwiftUI

extension Theme {
    /// How a recognised piece of capture grammar is drawn inside a text field.
    ///
    /// ### Why a token is drawn at all
    /// `#landscape` typed into a plain field is eleven characters that happen to start with a hash.
    /// The app has already decided it is a tag — the interpretation row says so — but the text itself
    /// still reads as punctuation, and it still deletes one letter at a time like punctuation. Giving
    /// it a fill makes the decision visible where the decision was made, and gives the user something
    /// to aim Delete at.
    ///
    /// ### Why the accent colour, when selection is also the accent colour
    /// Because the accent colour *is* the brand, and the two are never confusable in practice: a
    /// token is a rounded fill at a seventh of full strength with tinted text inside it, and a
    /// selection is a square fill at full strength with the text left alone. Picking a third colour
    /// to be safe would mean either taking one that already means something here — orange is
    /// unconfirmed, red is overdue, green is done, teal is personal, indigo is work — or inventing a
    /// decorative one, which is the thing this design system exists to avoid.
    ///
    /// ### Why syntax the parser could not use is drawn differently
    /// `#!!` looks like a tag and is not one. Drawing it as a token would be the interface claiming
    /// something the save path will not do. It gets a quiet amber underline instead: enough to say
    /// *this looked like syntax and did not work*, not enough to look like a failure, and it stays
    /// ordinary text that deletes one letter at a time — which is how the user fixes it.
    public enum CaptureToken {
        /// The rounded fill behind an understood token.
        public static var fill: NSColor {
            .controlAccentColor.withAlphaComponent(0.15)
        }

        /// The text inside an understood token.
        ///
        /// The accent colour at full strength rather than the label colour, so a token reads as a
        /// token in a monochrome screenshot and at a glance.
        public static var foreground: NSColor { .controlAccentColor }

        /// The mark under syntax the parser did not understand.
        public static var unresolvedUnderline: NSColor { .systemOrange }

        /// How far the fill extends past the glyphs, horizontally and vertically.
        ///
        /// Small on purpose. A token in a one-line capture field sits between ordinary words, and a
        /// pill with generous padding pushes the line height around as soon as one appears — which
        /// makes the field jump while somebody is typing into it.
        public static let padding = NSSize(width: 2, height: 1)

        /// Matches ``Theme/Radius/small``, which is what every other chip in the app uses.
        public static let cornerRadius: CGFloat = Theme.Radius.small
    }
}

extension Theme.CaptureToken {
    /// The SwiftUI mirror of ``foreground``, for the parts of the panel that are not a text view.
    public static var accent: Color { Color(nsColor: foreground) }
}

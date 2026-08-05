import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// A person's face, or their monogram in a tinted circle — one algorithm, one look.
///
/// Four implementations existed, at four sizes with four fonts and *two different rules* for
/// deriving the initials, so the same person could carry two monograms on two screens. The
/// derivation lives here alone.
///
/// ### Why a photograph belongs in the same type as the monogram
/// They are the same slot answering the same question, and which one appears is a property of the
/// person rather than of the screen. A separate `PersonPhoto` view would mean every call site
/// deciding for itself what to fall back to and how big the circle is — which is exactly how four
/// monograms happened. So the photograph is a parameter: pass bytes and you get a face, pass
/// nothing and you get the letters, and the circle is the same circle either way.
///
/// The monogram is drawn *underneath* rather than instead of the picture, so the moment before a
/// thumbnail arrives is a person's initials rather than a hole. The two never disagree, because a
/// face that has loaded covers the letters completely.
///
/// ### What it does not do
/// It does not fetch anything. The bytes come from `ContactPhotoStore`, which is where the
/// on-demand read and the cache live; the address book is not something a view gets to touch. And
/// it stores nothing: a contact photograph belongs to Contacts, and this draws it for as long as
/// the row is on screen.
public struct Avatar: View {
    /// Set on a selected row in an AppKit list — see ``fill``.
    @Environment(\.backgroundProminence) private var prominence

    private let name: String
    private let diameter: CGFloat
    private let tint: Color
    private let photo: Data?

    /// Decoded off the render pass, so a scroll is not decoding JPEGs inside `body`.
    @State private var face: Image?

    public init(
        name: String,
        diameter: CGFloat = Theme.Size.iconTileMedium,
        tint: Color = .accentColor,
        photo: Data? = nil
    ) {
        self.name = name
        self.diameter = diameter
        self.tint = tint
        self.photo = photo
    }

    public var body: some View {
        monogram
            .overlay {
                if let face {
                    face
                        .resizable()
                        // Filled and clipped, never squashed: a contact thumbnail is square in
                        // Contacts and rectangular everywhere it came from, and a face stretched
                        // to fit is worse than a face cropped to fit.
                        .scaledToFill()
                        .frame(width: diameter, height: diameter)
                        .clipShape(.circle)
                        // A pale photograph on a pale list has no edge of its own. The hairline is
                        // the same separator every other boundary in the app uses, so it holds in
                        // both appearances and strengthens under Increase Contrast.
                        .overlay(Circle().strokeBorder(Theme.Colors.separator))
                }
            }
            .frame(width: diameter, height: diameter)
            .calmAnimation(Theme.Motion.appearance, value: face != nil)
            .task(id: photo) { face = Self.decode(photo) }
            .accessibilityHidden(true)
    }

    private var monogram: some View {
        Text(Self.initials(from: name))
            .font(.system(.body, design: .rounded, weight: .semibold))
            // The monogram tracks the circle, not the text size: an avatar is an image made of
            // letters, and one that outgrew its circle would clip. Scaling down only, so large
            // accessibility sizes shrink the monogram into its circle instead of overflowing it.
            .minimumScaleFactor(0.5)
            .foregroundStyle(foreground)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(fill))
    }

    /// True only while the row is selected *and* the window is focused — the same condition under
    /// which the row is painted with the accent colour rather than an inert grey.
    private var isOnSelectedRow: Bool { prominence == .increased }

    /// The palette tint is a pale wash with the same colour written over it, which is legible on a
    /// list's own background and nowhere near legible on the accent fill of a selected row — the
    /// circle all but vanishes and the initials go muddy. On a selected row the avatar drops the
    /// colour and borrows the system's own selected-row styles, which resolve against whatever
    /// accent the user chose. The colour is worth less than being readable, and it comes straight
    /// back the moment the row is deselected.
    private var fill: AnyShapeStyle {
        isOnSelectedRow
            ? AnyShapeStyle(.quaternary)
            : AnyShapeStyle(Theme.Colors.tintedFill(tint))
    }

    private var foreground: AnyShapeStyle {
        isOnSelectedRow ? AnyShapeStyle(.primary) : AnyShapeStyle(tint)
    }

    /// The first letters of the first and last words — "Amara Okonjo" → "AO", "Cher" → "C".
    ///
    /// ### Why only words that begin with a letter count
    /// A monogram is made of letters. Taking the last word whatever it was put digits in the circle
    /// the moment a name ended in one — "Amara Abara 1" came out **A1**, and a seeded library of a
    /// hundred and fifty read as a column of serial numbers. Real names do it too: a record
    /// disambiguated as "John Smith 2" or filed as "Wing 3" is not somebody whose initials are J2.
    /// Skipping non-alphabetic words gives "Amara Abara 1" → AA and leaves every ordinary name
    /// exactly as it was.
    public static func initials(from name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }

        guard let first = words.first?.first else {
            // Nothing alphabetic anywhere — a record called "1975" or "☂" keeps its own first
            // character, because an empty circle says less than a wrong letter would.
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
                .first.map { String($0).uppercased() } ?? ""
        }

        let letters = [first, words.count > 1 ? words.last?.first : nil].compactMap { $0 }
        return letters.map(String.init).joined().uppercased()
    }

    /// Bytes to something drawable, or `nil` for anything that is not an image.
    ///
    /// `nil` rather than a broken-image glyph on purpose: the fallback is already correct and
    /// already on screen. Undecodable bytes are indistinguishable from no bytes as far as this
    /// slot is concerned, and the monogram is a better answer than an apology.
    private static func decode(_ data: Data?) -> Image? {
        guard let data, !data.isEmpty else { return nil }

        #if canImport(UIKit)
            return UIImage(data: data).map(Image.init(uiImage:))
        #elseif canImport(AppKit)
            return NSImage(data: data).map(Image.init(nsImage:))
        #else
            return nil
        #endif
    }
}

#Preview("Avatars") {
    HStack(spacing: Theme.Spacing.large) {
        Avatar(name: "Amara Okonjo", diameter: Theme.Size.iconTileSmall, tint: Theme.Palette.teal.color)
        Avatar(name: "Maya Chen", tint: Theme.Palette.indigo.color)
        Avatar(name: "Cher", diameter: Theme.Size.iconTileLarge, tint: Theme.Palette.pink.color)
        Avatar(name: "", diameter: Theme.Size.iconTileLarge, tint: Theme.Palette.graphite.color)
    }
    .padding(Theme.Spacing.section)
}

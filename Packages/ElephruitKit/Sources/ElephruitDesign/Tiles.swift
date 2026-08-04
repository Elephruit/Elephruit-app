import SwiftUI

// MARK: - Icon tile

/// A glyph in a tinted rounded square — the app's one answer to an idea it had six of.
///
/// Six hand-built versions existed, at five sizes with five radii and five fill alphas, no two
/// identical: the portrait's fact categories, the contact editor's rows and its page picker, the
/// fact sheet, the capture sheet, the timeline sheet. This is that component, in the three sizes
/// that survive. The glyph scales with Dynamic Type because it is set in a text style; the tile
/// is fixed, which is what keeps a grid of them a grid.
public struct IconTile: View {
    public enum Size: Sendable {
        /// 24 pt — inside a row.
        case small
        /// 32 pt — anchoring a card or a picker.
        case medium
        /// 44 pt — an identity, at the top of a sheet or a page.
        case large

        var side: CGFloat {
            switch self {
            case .small: Theme.Size.iconTileSmall
            case .medium: Theme.Size.iconTileMedium
            case .large: Theme.Size.iconTileLarge
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .small, .medium: Theme.Radius.medium
            case .large: Theme.Radius.large
            }
        }

        var font: Font {
            switch self {
            case .small: .system(.callout, weight: .semibold)
            case .medium: .system(.title3, weight: .semibold)
            case .large: .system(.title2, weight: .semibold)
            }
        }
    }

    private let systemImage: String
    private let tint: Color
    private let size: Size

    public init(systemImage: String, tint: Color, size: Size = .medium) {
        self.systemImage = systemImage
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        Image(systemName: systemImage)
            .font(size.font)
            .foregroundStyle(tint)
            .frame(width: size.side, height: size.side)
            .background(
                RoundedRectangle(cornerRadius: size.cornerRadius)
                    .fill(Theme.Colors.tintedFill(tint))
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Avatar

/// A person's monogram in a circle — one algorithm, one look.
///
/// Four implementations existed, at four sizes with four fonts and *two different rules* for
/// deriving the initials, so the same person could carry two monograms on two screens. The
/// derivation lives here alone.
public struct Avatar: View {
    private let name: String
    private let diameter: CGFloat
    private let tint: Color

    public init(name: String, diameter: CGFloat = Theme.Size.iconTileMedium, tint: Color = .accentColor) {
        self.name = name
        self.diameter = diameter
        self.tint = tint
    }

    public var body: some View {
        Text(Self.initials(from: name))
            .font(.system(.body, design: .rounded, weight: .semibold))
            // The monogram tracks the circle, not the text size: an avatar is an image made of
            // letters, and one that outgrew its circle would clip. Scaling down only, so large
            // accessibility sizes shrink the monogram into its circle instead of overflowing it.
            .minimumScaleFactor(0.5)
            .foregroundStyle(tint)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Theme.Colors.tintedFill(tint)))
            .accessibilityHidden(true)
    }

    /// The first letters of the first and last words — "Amara Okonjo" → "AO", "Cher" → "C".
    public static func initials(from name: String) -> String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        let letters = [words.first, words.count > 1 ? words.last : nil]
            .compactMap { $0?.first }
        return letters.map(String.init).joined().uppercased()
    }
}

// MARK: - Chip

/// A small capsule of metadata — a tag, a person, a token, a state.
///
/// `TagChip` stays the specialist for tags (it owns tag colour resolution); this is the general
/// form the other eight local chip types and twenty-six hand-built capsules converge on. Tinted
/// when the content has a colour of its own, neutral when it does not, removable when the caller
/// says so.
public struct Chip: View {
    private let text: String
    private let systemImage: String?
    private let tint: Color?
    private let onRemove: (() -> Void)?

    public init(
        _ text: String,
        systemImage: String? = nil,
        tint: Color? = nil,
        onRemove: (() -> Void)? = nil
    ) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(Theme.Text.keyHint)
                    .accessibilityHidden(true)
            }

            Text(text)
                .font(Theme.Text.chip)
                .lineLimit(1)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(Theme.Text.keyHint)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(text)")
            }
        }
        .foregroundStyle(tint ?? Theme.Colors.secondaryText)
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.hairline)
        .background(
            Capsule().fill(tint.map(Theme.Colors.tintedFill) ?? Theme.Colors.subtleFill)
        )
        // The boundary is what stopped chips dissolving into the dark list background —
        // the fills alone were close enough to the surface to vanish.
        .overlay(
            Capsule().strokeBorder(
                tint.map(Theme.Colors.tintedStroke) ?? Theme.Colors.separator
            )
        )
        // Drawn whole or not at all: a chip that wraps one character per line is the layout
        // fault the first audit opened with.
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

#Preview("Tiles, avatars, chips") {
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        HStack(spacing: Theme.Spacing.medium) {
            IconTile(systemImage: "fork.knife", tint: Theme.Palette.orange.color, size: .small)
            IconTile(systemImage: "person.2", tint: Theme.Palette.indigo.color, size: .medium)
            IconTile(systemImage: "gift", tint: Theme.Palette.pink.color, size: .large)
        }
        HStack(spacing: Theme.Spacing.medium) {
            Avatar(name: "Amara Okonjo", diameter: Theme.Size.iconTileSmall)
            Avatar(name: "Amara Okonjo")
            Avatar(name: "Cher", diameter: Theme.Size.iconTileLarge, tint: Theme.Palette.teal.color)
        }
        HStack(spacing: Theme.Spacing.small) {
            Chip("follow-up")
            Chip("urgent", tint: Theme.Palette.red.color)
            Chip("Maya Chen", systemImage: "person", tint: Theme.Palette.indigo.color, onRemove: {})
        }
    }
    .padding()
}

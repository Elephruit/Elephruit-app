import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The one way an item is drawn in a list on the iPhone.
///
/// One row for every kind, exactly as the redesigned Mac settled on — four different row
/// layouts for the same object was that audit's largest consistency finding, and it does
/// not get to happen again here. Kind differences are expressed by which fields exist,
/// never by a different anatomy: leading glyph or completion control, title, one line of
/// context, a date on the trailing edge.
struct MobileItemRow: View {
    @Environment(\.services) private var services

    let item: Item
    /// Off where the surrounding section already names the container — a row saying
    /// "Planning" under a header saying "Planning" is the list stuttering.
    var showsParent = true
    /// Present when tapping the leading control should toggle completion.
    var onToggleCompletion: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.medium) {
            leadingControl

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(item.displayTitle)
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(titleStyle)
                    .strikethrough(item.status == .completed, color: Theme.Colors.tertiaryText)
                    .lineLimit(2)

                if let context = contextLine {
                    Text(context)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            trailingDate
        }
        // 44 points before padding: the comfortable touch minimum, not the Mac's 28.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var leadingControl: some View {
        if item.kind.supportsStatus, let onToggleCompletion {
            Button(action: onToggleCompletion) {
                Image(systemName: item.status == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(
                        item.status == .completed ? Theme.Colors.completed : Theme.Colors.secondaryText
                    )
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.status == .completed ? "Completed" : "Not completed")
            .accessibilityHint("Double-tap to toggle")
        } else {
            Image(systemName: item.effectiveSymbolName)
                .font(.body)
                .foregroundStyle(glyphColor)
                .frame(width: 32)
                .accessibilityHidden(true)
        }
    }

    private var glyphColor: Color {
        if let name = item.colorName {
            return Theme.Palette.color(named: name)
        }
        return Theme.Colors.secondaryText
    }

    private var titleStyle: Color {
        if item.hasPlaceholderTitle { return Theme.Colors.placeholderText }
        if item.status == .completed { return Theme.Colors.secondaryText }
        return Theme.Colors.primaryText
    }

    /// Parent · excerpt · tags, whichever exist, in that order.
    private var contextLine: String? {
        var parts: [String] = []
        if showsParent, let parent = item.parentTitle, !parent.isEmpty {
            parts.append(parent)
        }
        if item.kind == .note || item.kind == .idea || item.kind == .reference {
            let excerpt = item.excerpt
            // The untitled-note rule from the Mac audit: when the body is standing in as the
            // title, it does not also get to be the subtitle.
            if !excerpt.isEmpty, !item.hasPlaceholderTitle {
                parts.append(excerpt)
            }
        }
        if !item.tagSlugs.isEmpty {
            parts.append(item.tagSlugs.map { "#\($0)" }.joined(separator: " "))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailingDate: some View {
        if let services, let resolved = RowDate.resolve(for: item) {
            RowDateLabel(
                resolved: resolved,
                dateProvider: services.dateProvider,
                isActionable: item.isActionable
            )
        }
    }
}

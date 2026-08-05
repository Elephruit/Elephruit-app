import ElephruitDesign
import SwiftUI

/// The drawer: every place the app has, one tap each.
///
/// A plain `ScrollView` of buttons rather than a `List`. A list's separators, insets and
/// chevrons are furniture for rows that *contain* things; these rows only name places, and the
/// selected one has to read as selected — which a list row cannot do on iOS without fighting
/// its own background.
struct MobileSidebar: View {
    @Environment(MobileShellModel.self) private var shell

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    ForEach(Array(MobileDestination.groups.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                            ForEach(group, id: \.self) { destination in
                                row(destination)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.bottom, Theme.Spacing.section)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.Colors.windowBackground)
        // `.contain` rather than a bare identifier: an identifier on a stack is inherited by
        // every child that has none of its own, which had left the header text and the scroll
        // view both answering to "mobile.sidebar" and nothing answering as the drawer itself.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mobile.sidebar")
    }

    /// The app's name, once, where a title bar would be. The screen behind the drawer names
    /// itself; the drawer names the thing all of those screens belong to.
    private var header: some View {
        Text("Elephruit")
            .font(Theme.Text.title)
            .foregroundStyle(Theme.Colors.primaryText)
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.top, Theme.Spacing.large)
            .padding(.bottom, Theme.Spacing.medium)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ destination: MobileDestination) -> some View {
        let isSelected = shell.destination == destination
        return Button {
            withCalmAnimation { shell.select(destination) }
        } label: {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: destination.symbolName)
                    // A fixed glyph column: symbols have wildly different intrinsic widths, and
                    // labels that start at fourteen different x positions read as fourteen
                    // unrelated controls.
                    .frame(width: 26, alignment: .center)
                    .foregroundStyle(isSelected ? Theme.Colors.onAccent : Theme.Colors.secondaryText)

                Text(destination.title)
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(isSelected ? Theme.Colors.onAccent : Theme.Colors.primaryText)

                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, Theme.Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Theme.Colors.selection) : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(destination.hint)
        .accessibilityIdentifier("mobile.sidebar.\(destination.rawValue)")
    }
}

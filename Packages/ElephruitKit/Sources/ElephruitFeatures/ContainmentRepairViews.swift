import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// A quiet line offering to convert old containment into filings.
///
/// A banner rather than a modal on launch. The conversion is not urgent, the library works perfectly
/// well without it, and interrupting someone before they have looked at their own notes to demand a
/// decision about a data migration is the opposite of calm.
struct ContainmentRepairBanner: View {
    let report: MigrationReport
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Theme.Colors.secondaryText)
                .accessibilityHidden(true)

            Text(headline)
                .font(Theme.Text.rowSubtitle)

            Spacer(minLength: Theme.Spacing.small)

            Button("Review…", action: onReview)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("containmentRepair.banner")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headline)
    }

    private var headline: String {
        let count = report.conversions.count
        guard count > 0 else {
            return "Some items are filed in a way this version no longer uses."
        }
        return count == 1
            ? "1 item is filed in a way this version no longer uses."
            : "\(count) items are filed in a way this version no longer uses."
    }
}

/// The report, shown in full before anything is changed.
///
/// Everything the migration will do, item by item, with the non-destructive option — doing nothing —
/// available and unpenalised. The user can leave and the library keeps working exactly as it does now.
struct ContainmentRepairSheet: View {
    let report: MigrationReport
    let onApply: () -> Void
    let onDefer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            header
            explanation

            if !report.conversions.isEmpty {
                conversionList
            }

            if !report.unresolved.isEmpty {
                unresolvedList
            }

            Divider()
            footer
        }
        .padding(Theme.Spacing.large)
        .frame(width: 560)
        .accessibilityIdentifier("containmentRepair.sheet")
    }

    private var header: some View {
        Label("Update how these items are filed", systemImage: "arrow.triangle.branch")
            .font(.system(.headline, design: .default, weight: .medium))
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(
                """
                Notes and other content used to live *inside* a project. They are now *linked* to one \
                instead, which lets a note belong to several projects and means archiving a project no \
                longer takes its notes with it.
                """
            )
            .fixedSize(horizontal: false, vertical: true)

            Text("Nothing is deleted. Your library is backed up first, and this can be run again safely.")
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Text.rowSubtitle)
    }

    private var conversionList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            SectionHeader("Will be filed under", count: report.conversions.count)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    ForEach(report.conversions, id: \.itemID) { conversion in
                        HStack(spacing: Theme.Spacing.small) {
                            Text(conversion.itemTitle)
                                .lineLimit(1)
                            Image(systemName: "arrow.right")
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                            Text(conversion.containerTitle)
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .lineLimit(1)
                            Spacer()
                        }
                        .font(Theme.Text.rowSubtitle)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }

    /// Shown rather than hidden. An item the migration cannot place is exactly what the user needs to
    /// know about, and burying it would be the one dishonest thing this sheet could do.
    private var unresolvedList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            SectionHeader("Could not be filed", count: report.unresolved.count)

            ForEach(report.unresolved.prefix(6), id: \.itemID) { item in
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.itemTitle).lineLimit(1)
                    Text(item.reason)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .font(Theme.Text.rowSubtitle)
            }

            Text("These will be moved to the top level so they stay editable.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(report.itemsExamined) items examined")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)

            Spacer()

            Button("Not Now", action: onDefer)
                .keyboardShortcut(.cancelAction)

            Button("Update Filing", action: onApply)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!report.hasWork && report.unresolved.isEmpty)
        }
    }
}

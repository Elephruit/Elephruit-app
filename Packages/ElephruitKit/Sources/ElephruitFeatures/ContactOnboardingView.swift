import ElephruitCore
import ElephruitDesign
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Bringing the address book in, from the explanation through to the last row written.
///
/// ### Why the explanation comes before the prompt
/// A permission dialogue that appears before anybody has decided the feature is wanted is what gets
/// an app denied permanently — and on macOS a denial is permanent, recoverable only through System
/// Settings. So this screen says what will happen, what stays local, and what the app will never do,
/// and the system prompt follows a deliberate press. That ordering is the single most important thing
/// on this screen.
public struct ContactOnboardingView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let navigation: NavigationModel
    let completionSelection: SidebarSelection

    @State private var model: ContactImportModel?

    public init(navigation: NavigationModel, completionSelection: SidebarSelection = .records(.unsorted)) {
        self.navigation = navigation
        self.completionSelection = completionSelection
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let model {
                content(model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 640, height: 560)
        .accessibilityIdentifier(AccessibilityID.Records.contactOnboarding)
        .task {
            guard model == nil, let services else { return }
            let created = ContactImportModel(services: services)
            model = created
            await created.prepare()
        }
    }

    @ViewBuilder
    private func content(_ model: ContactImportModel) -> some View {
        switch model.phase {
        case .explaining:
            ContactExplanationView(
                onContinue: { Task { await model.requestAccess() } },
                onCancel: { dismiss() }
            )

        case .requestingAccess:
            ContactWaitingView(
                headline: "Waiting for permission",
                message: "macOS is asking whether Elephruit may read your contacts."
            )

        case .accessDenied:
            ContactAccessRefusedView(
                title: "Contacts access is off",
                message: """
                    Elephruit cannot read your address book. macOS remembers this answer, so the \
                    prompt will not appear again — you can change it in System Settings.
                    """,
                showsSettingsButton: true,
                onDismiss: { dismiss() }
            )

        case .accessRestricted:
            ContactAccessRefusedView(
                title: "Contacts is not available",
                message: """
                    Access to contacts is managed on this Mac, perhaps by a configuration profile or \
                    parental controls, so it is not yours to turn on. Everything else in People \
                    works: you can add people by hand at any time.
                    """,
                showsSettingsButton: false,
                onDismiss: { dismiss() }
            )

        case .scanning(let progress):
            ContactWaitingView(
                headline: "Reading your address book",
                message: "Nothing has been added yet. You will see a summary first.",
                progress: progress
            )

        case .empty:
            ContactEmptyView(onDismiss: { dismiss() })

        case .reviewing:
            ContactImportReviewView(model: model, onCancel: { dismiss() })

        case .importing(let progress):
            ContactWaitingView(
                headline: "Adding contact records",
                message: "You can stop at any time. Everything already added is kept.",
                progress: progress,
                onCancel: { model.cancel() }
            )

        case .finished(let report):
            ContactImportFinishedView(
                report: report,
                onReviewAgain: { model.reviewAgain() },
                onDone: {
                    navigation.select(completionSelection)
                    dismiss()
                }
            )

        case .accessRevoked:
            ContactAccessRefusedView(
                title: "Contacts access was turned off",
                message: """
                    Everyone already in Records is kept, along with everything you recorded about \
                    them. Linked details can no longer refresh until access is restored.
                    """,
                showsSettingsButton: true,
                onDismiss: { dismiss() }
            )

        case .failed(let reason):
            ContactAccessRefusedView(
                title: "That did not work",
                message: reason,
                showsSettingsButton: false,
                onDismiss: { dismiss() }
            )
        }
    }
}

// MARK: - The explanation

/// What the app will and will not do, before anything is asked.
struct ContactExplanationView: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Image(systemName: "person.crop.rectangle.stack")
                    .font(Theme.Text.heroGlyph)
                    .foregroundStyle(Theme.Colors.selection)

                Text("Start from the contacts you already know")
                    .font(Theme.Text.title)

                Text("""
                    Elephruit can use the contacts already on this Mac — from iCloud, Google, \
                    Exchange, or On My Mac — as the starting point for your Records. You will see \
                    exactly what it proposes before anything is added.
                    """)
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                // "Elephruit has no network access at all" was true of the binary that shipped
                // without a network-client entitlement, and stopped being true when sync arrived.
                // Rewritten to say where things go rather than to deny that anything goes anywhere,
                // because this sheet is read by somebody deciding whether to hand over an address
                // book, and a sentence they can disprove costs more than it buys.
                factRow(
                    "lock.shield",
                    "Nothing here is uploaded to us",
                    """
                    Contacts are read locally, and there is no Elephruit account and no Elephruit \
                    server. What this import makes stays on this Mac unless you turn on iCloud \
                    sync, and then it goes to your own private database and nowhere else.
                    """
                )
                factRow(
                    "arrow.left.arrow.right.circle",
                    "Your notes never go back into Contacts",
                    """
                    Private reflections, relationship history, tasks, tags, confidence, and \
                    provenance stay in Elephruit. Your address book never sees them.
                    """
                )
                factRow(
                    "pencil.slash",
                    "Your contacts are never changed",
                    "Elephruit only reads. It has no code that could modify a contact, and it never will without you asking."
                )
                factRow(
                    "checkmark.shield",
                    "Turning access off later keeps your work",
                    "Everything you record here is yours and stays here, whatever happens to the permission."
                )
            }

            Spacer()

            HStack {
                Button("Not now", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }

            Text("macOS will ask for permission next.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(Theme.Spacing.section)
        .accessibilityIdentifier(AccessibilityID.Records.contactExplanation)
    }

    private func factRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Image(systemName: symbol)
                .font(.system(.title3))
                .foregroundStyle(Theme.Colors.selection)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Text.rowTitleEmphasised)
                Text(detail)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}

// MARK: - Waiting

/// Scanning, importing, or waiting on the system.
struct ContactWaitingView: View {
    let headline: String
    let message: String
    var progress: ContactImportProgress?
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Spacer()

            if let progress, progress.total > 0 {
                ProgressView(value: progress.fraction) {
                    Text(headline).font(Theme.Text.title)
                } currentValueLabel: {
                    Text("\(progress.processed) of \(progress.total)")
                        .font(Theme.Text.metadata)
                        .monospacedDigit()
                }
                .frame(maxWidth: 320)
                // Announced as it changes, so somebody using VoiceOver is not left guessing whether
                // a long import is still running.
                .accessibilityLabel(progress.accessibilityDescription)
            } else {
                ProgressView()
                Text(headline).font(Theme.Text.title)
            }

            Text(message)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            if let onCancel {
                Button("Stop", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, Theme.Spacing.small)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.section)
    }
}

// MARK: - Refused

/// Denied, restricted, revoked, or failed — with the one route out, when there is one.
struct ContactAccessRefusedView: View {
    let title: String
    let message: String
    let showsSettingsButton: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Spacer()

            Image(systemName: "lock.slash")
                .font(Theme.Text.heroGlyph)
                .foregroundStyle(Theme.Colors.secondaryText)

            Text(title).font(Theme.Text.title)

            Text(message)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)

            Label(
                "Records still works. You can add records by hand, and everything already here is kept.",
                systemImage: "info.circle"
            )
            .font(Theme.Text.metadata)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .padding(.top, Theme.Spacing.small)

            HStack(spacing: Theme.Spacing.small) {
                if showsSettingsButton {
                    Button("Open System Settings") { ContactPrivacySettings.open() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, Theme.Spacing.small)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.section)
        .accessibilityIdentifier(AccessibilityID.Records.contactAccessRefused)
    }
}

/// Opens the Contacts privacy pane.
///
/// The URL is the documented `x-apple.systempreferences:` scheme with the Contacts anchor. If a
/// future macOS renames it, `NSWorkspace.open` returns `false` and the fallback opens the top level
/// of System Settings — which is one step further from the switch but never a button that does
/// nothing.
enum ContactPrivacySettings {
    static let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")

    static func open() {
        guard let url, NSWorkspace.shared.open(url) else {
            if let fallback = URL(string: "x-apple.systempreferences:") {
                NSWorkspace.shared.open(fallback)
            }
            return
        }
    }
}

// MARK: - Empty

struct ContactEmptyView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Spacer()
            EmptyStateView(
                symbolName: "person.crop.circle.badge.questionmark",
                headline: "No contacts found",
                message: """
                    Elephruit can read your address book, and there is nothing in it yet. Add people \
                    here by hand, or add them in Contacts and come back.
                    """
            )
            Button("Close", action: onDismiss)
                .keyboardShortcut(.cancelAction)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.section)
    }
}

// MARK: - Finished

struct ContactImportFinishedView: View {
    let report: ContactImportReport
    let onReviewAgain: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Spacer()

            Image(systemName: report.isCompleteSuccess ? "checkmark.circle" : "exclamationmark.circle")
                .font(Theme.Text.heroGlyph)
                .foregroundStyle(report.isCompleteSuccess ? Theme.Colors.completed : Theme.Colors.warning)

            Text(report.wasCancelled ? "Stopped" : "Done")
                .font(Theme.Text.title)

            Text(report.summary)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .multilineTextAlignment(.center)

            if !report.failures.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text("These could not be read")
                        .font(Theme.Text.sectionHeader)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    ForEach(report.failures.prefix(6)) { failure in
                        Text("\(failure.name) — \(failure.reason)")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    if report.failures.count > 6 {
                        Text("…and \(report.failures.count - 6) more.")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
                .frame(maxWidth: 400, alignment: .leading)
                .padding(Theme.Spacing.medium)
                .background(
                    Theme.Colors.subtleFill,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                )
            }

            HStack(spacing: Theme.Spacing.small) {
                if report.wasCancelled || !report.failures.isEmpty {
                    Button("Review again", action: onReviewAgain)
                        .help("Nothing already added will be added twice")
                }
                Button("Go to Records", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, Theme.Spacing.small)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.section)
        .accessibilityIdentifier(AccessibilityID.Records.contactImportFinished)
    }
}

import AppKit

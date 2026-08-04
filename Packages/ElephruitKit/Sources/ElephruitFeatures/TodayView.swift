import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The day, whole.
///
/// ### What this replaced, and why
/// Two destinations. Home said what is *happening* — meetings, the day's note, who has gone quiet —
/// and Upcoming said what is *dated*, which is largely the same records sorted differently. Somebody
/// opening the app in the morning read both and did the joining themselves, because neither page
/// could do it: neither had seen the other's records. The join is the whole value. The person in
/// your ten o'clock is also the person a task is waiting on and also the person whose birthday it is,
/// and that is one row on this page rather than three rows on two pages.
///
/// ### The shape
/// A date-led flow rather than three dashboards. Each day is a marker and a column of what it holds;
/// the selected day gets the emphasis, the days after it are compact and open on request, and the
/// days before it are not there at all until asked for. Within a day the order is the order somebody
/// plans in: what the day *is*, then what is wrong, then what is fixed in time, then what is not,
/// then who, then what is already done.
///
/// ### What is deliberately not here
/// A card around every section, a tint behind every group, and a statistic that changes no decision.
/// Hierarchy is typography, spacing and alignment; colour is reserved for meaning, and red is
/// reserved for genuine urgency. Anything that would fill the width of an ultrawide display with a
/// single sentence is constrained by ``Theme/Size/todayContentWidth`` instead.
public struct TodayView: View {
    @Environment(\.services) private var services

    private let navigation: NavigationModel

    @State private var model: TodayModel?

    /// Which day the quick-add field is open on, if any. One at a time, because two open drafts is
    /// two places a Return could land.
    @State private var draftDay: Date?
    @State private var draftTitle = ""
    @FocusState private var isDraftFocused: Bool

    @State private var isDatePickerPresented = false

    /// The page's own width, which decides whether a day is one column or two.
    ///
    /// Measured rather than inferred from a size class: this is a column inside a resizable window,
    /// and what decides whether two columns fit is how wide the column is, not how wide the display
    /// is.
    @State private var availableWidth: CGFloat = Theme.Size.assumedWindowWidth

    public init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    public var body: some View {
        Group {
            if let model {
                page(model)
            } else {
                // Only before the model exists, which is one turn of the run loop at most.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.windowBackground)
        .task {
            guard model == nil, let services else { return }
            model = TodayModel(services: services)
        }
        // ⌘0 while already on Today: the page may be browsing another day, and re-selecting the
        // destination is the keyboard route back to the day itself.
        .onChange(of: navigation.todayReturnRequest) { _, _ in model?.returnToToday() }
        // The Edit menu's work-item verbs, meaning what they mean here: acting on the selected row.
        .focusedSceneValue(\.workItemActions, workItemCommandActions)
        .accessibilityIdentifier(AccessibilityID.Today.root)
    }

    /// The selected row's verbs for the Edit menu — complete, flag, move to today.
    private var workItemCommandActions: WorkItemCommandActions? {
        guard let model, let services,
              let id = navigation.selectedItemID,
              let task = model.task(id)
        else { return nil }

        let actions = TodayActions(services: services, navigation: navigation, model: model)
        return WorkItemCommandActions(
            isEnabled: true,
            isFlagged: task.isFlagged,
            complete: { actions.toggleCompletion(task) },
            toggleFlag: { actions.setFlagged(!task.isFlagged, on: task) },
            moveToToday: { actions.reschedule(task, to: services.dateProvider.startOfToday) }
        )
    }

    // MARK: - The page

    private func page(_ model: TodayModel) -> some View {
        VStack(spacing: 0) {
            if services?.calendar.isEnabled == false || services?.calendar.authorization.canRead == false {
                calendarBanner
            }

            content(model)
        }
        .navigationTitle(title(model))
        .navigationSubtitle(subtitle(model))
        // The window toolbar owns the day's controls now — the in-content bar this replaces was a
        // second row of chrome above the day, spending the day's own room.
        .toolbar {
            TodayToolbarItems(
                model: model,
                preferences: services?.todayPreferences,
                calendars: services?.calendar,
                isDatePickerPresented: $isDatePickerPresented
            )
        }
        // Moving the window is the only thing that reads the calendar. Everything else rebuilds the
        // days from what is already in memory — which is what stops the page asking the calendar a
        // question in response to the calendar having answered one. See `TodayModel.WindowToken`.
        .task(id: model.windowToken) { await model.reload() }
        .onChange(of: model.sourceToken) { _, _ in model.assemble() }
    }

    @ViewBuilder
    private func content(_ model: TodayModel) -> some View {
        if let failure = model.failure {
            FailureStateView(error: failure) { _ in
                Task { await model.reload() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isLoadingInitially {
            // A spinner rather than an empty page. An empty page and a clear day look identical, and
            // being told the day is clear before it has been read is the one thing this page must
            // never do.
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Assembling your day")
        } else {
            days(model)
        }
    }

    private func days(_ model: TodayModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                previousDaysControl(model)

                ForEach(model.previousDays) { plan in
                    compactDay(plan, model: model, isPast: true)
                }

                if let selected = model.selectedPlan {
                    TodayDayView(
                        plan: selected,
                        model: model,
                        navigation: navigation,
                        draftDay: $draftDay,
                        draftTitle: $draftTitle,
                        isDraftFocused: $isDraftFocused,
                        isWide: isWide
                    )
                    .padding(.vertical, Theme.Spacing.large)
                }

                ForEach(model.followingDays) { plan in
                    compactDay(plan, model: model, isPast: false)
                }

                loadMoreControl(model)
            }
            // The measure, from the inside. An ultrawide window gets margins rather than a briefing
            // stretched across a metre of glass — see `TodayLayout` for why the column itself is
            // unbounded.
            .frame(maxWidth: Theme.Size.todayContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.bottom, Theme.Spacing.generous)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            guard width > 0 else { return }
            availableWidth = width
        }
    }

    private var isWide: Bool {
        min(availableWidth, Theme.Size.todayContentWidth) >= Theme.Size.todayTwoColumnMinimum
    }

    @ViewBuilder
    private func compactDay(_ plan: DayPlan, model: TodayModel, isPast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.leading, TodayMetrics.railWidth)

            TodayCompactDayView(
                plan: plan,
                model: model,
                navigation: navigation,
                isPast: isPast,
                isWide: isWide
            )
            .padding(.vertical, Theme.Spacing.medium)
        }
    }

    // MARK: - Days behind and ahead

    @ViewBuilder
    private func previousDaysControl(_ model: TodayModel) -> some View {
        // Only ever offered from today itself. Standing on next Tuesday, "previous days" means the
        // days between here and now, which is not a question anybody asks in those words.
        if model.isOnToday {
            HStack {
                Button {
                    withAnimation(Theme.Motion.standard) {
                        model.isShowingPreviousDays ? model.hidePreviousDays() : model.showPreviousDays()
                    }
                } label: {
                    Label(
                        model.isShowingPreviousDays ? "Hide Previous Days" : "Show Previous Days",
                        systemImage: model.isShowingPreviousDays ? "chevron.up" : "clock.arrow.circlepath"
                    )
                    .font(Theme.Text.metadata)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.Colors.secondaryText)
                .accessibilityIdentifier(AccessibilityID.Today.showPreviousDays)

                Spacer()
            }
            .padding(.top, Theme.Spacing.medium)
        }
    }

    private func loadMoreControl(_ model: TodayModel) -> some View {
        HStack {
            Button {
                model.loadMoreDays()
            } label: {
                Label("Show Another Week", systemImage: "chevron.down")
                    .font(Theme.Text.metadata)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.Colors.secondaryText)
            .accessibilityIdentifier(AccessibilityID.Today.loadMoreDays)

            Spacer()
        }
        .padding(.leading, TodayMetrics.railWidth)
        .padding(.top, Theme.Spacing.large)
    }

    // MARK: - The calendar's own state

    @ViewBuilder
    private var calendarBanner: some View {
        if let calendar = services?.calendar {
            CalendarStatusBanner(
                authorization: calendar.authorization,
                isEnabled: calendar.isEnabled,
                onEnable: { Task { _ = await calendar.enable() } },
                onOpenSettings: { CalendarSettingsLink.open() }
            )
        }
    }

    // MARK: - Titles

    private func title(_ model: TodayModel) -> String {
        model.isOnToday ? "Today" : model.selectedDate.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// The one line the window title bar can carry, which is the one figure that changes what
    /// somebody does next.
    private func subtitle(_ model: TodayModel) -> String {
        guard let plan = model.selectedPlan else { return "" }
        let figures = plan.briefing.figures
        guard !figures.isEmpty else { return plan.briefing.isClear ? "Clear" : "" }
        return figures.map { "\($0.value) \($0.label)" }.joined(separator: " · ")
    }
}

/// Numbers the day's two columns agree on.
///
/// Here rather than beside each use because the whole point of the rail is that every day's marker
/// starts at the same x and every day's content starts at the same x — a value repeated in four
/// views is four chances for one of them to be four points out, which reads as a wobble down the
/// length of the page.
enum TodayMetrics {
    /// The date marker column.
    static let railWidth: CGFloat = 116

    /// The gutter that holds a time, so times and titles line up between events and tasks.
    static let timeGutterWidth: CGFloat = 62
}

#Preview("Today", traits: .fixedLayout(width: 1180, height: 820)) {
    TodayView(navigation: NavigationModel())
        .appServices(AppServices.inMemory())
        .frame(width: 1180, height: 820)
}

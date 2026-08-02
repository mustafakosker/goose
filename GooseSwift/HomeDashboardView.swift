import SwiftUI

struct HomeDashboardView: View {
  @EnvironmentObject private var model: GooseAppModel
  @EnvironmentObject private var router: AppRouter
  @ObservedObject var healthStore: HealthDataStore
  @Binding var selectedDate: Date
  let openHealthRoute: (HealthRoute) -> Void
  @State private var showingScoreDatePicker = false
  @State private var showingCardioLoadSheet = false
  @State private var selectedHealthMonitorTrend: HealthMetricSnapshot?

  var body: some View {
    let snapshots = HomeSnapshotSet(store: healthStore, model: model, selectedDate: selectedDate)

    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        HomeDailyScoreCard(
          scores: snapshots.scores,
          actionSummary: dailyActionSummary,
          coachTip: CoachTipFactory.homeTip(healthStore: healthStore, appModel: model),
          openScore: openHealth,
          openCoach: openCoach
        )

        HomeStressEnergySection(
          stress: snapshots.landing(for: .stress),
          energy: snapshots.landing(for: .energyBank),
          openStress: { openHealth(.stress) }
        )

        HomeCardioLoadWidget(
          snapshot: snapshots.landing(for: .cardioLoad),
          days: healthStore.cardioLoadWeeklyPoints()
        ) {
          showingCardioLoadSheet = true
          model.recordUIAction("health.sheet.opened", detail: "Cardio Load home widget")
        }

        HomeHealthMonitorSection(
          snapshots: healthStore.healthMonitorSnapshots(allowLiveFallbacks: false),
          openSnapshot: openHealthMonitorSnapshot
        )

        HomeTimelineSection(
          sleep: snapshots.home(for: .sleep),
          activity: snapshots.home(for: .strain),
          recovery: snapshots.home(for: .recovery),
          activities: model.homeActivityTimelineItems,
          openSleep: { openHealth(.sleep) },
          openActivity: { openHealth(.strain) },
          openRecovery: { openHealth(.recovery) }
        )

      }
      .padding(.horizontal, 16)
      .padding(.vertical, 18)
    }
    .scrollClipDisabled()
    .gooseScreenBackground()
    .navigationTitle("Today")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .overlay(alignment: .top) {
      HomeTopScrollFade()
        .allowsHitTesting(false)
    }
    .safeAreaInset(edge: .bottom, alignment: .trailing) {
      HomeStartActivityFloatingButton(session: model.activitySession)
        .padding(.trailing, 18)
        .padding(.bottom, 10)
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        ScoreDateTitleButton(
          title: homeTitle,
          subtitle: nil,
          action: { showingScoreDatePicker = true }
        )
      }
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink {
          DeviceView()
        } label: {
          Image(systemName: "applewatch")
            .font(.system(size: 17, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(deviceToolbarTint)
        }
        .accessibilityLabel("Device")
        .accessibilityValue(deviceToolbarAccessibilityValue)
      }
    }
    .onAppear {
      model.recordUIAction("page.opened", detail: "Home")
    }
    .task {
      healthStore.loadBridgeCatalogsIfNeeded()
      model.refreshActivityTimeline(for: selectedDate)
    }
    .onChange(of: selectedDate) { _, newValue in
      model.refreshActivityTimeline(for: newValue)
    }
    .sheet(isPresented: $showingScoreDatePicker) {
      ScoreDatePickerSheet(
        title: "Daily Scores",
        routes: [.sleep, .recovery, .strain],
        snapshots: scorePickerSnapshots,
        selectedDate: $selectedDate
      )
    }
    .sheet(isPresented: $showingCardioLoadSheet) {
      CardioLoadSheet(store: healthStore)
    }
    .sheet(item: $selectedHealthMonitorTrend) { snapshot in
      SleepV2BevelTrendSheet(snapshot: snapshot)
    }
  }

  private var scorePickerSnapshots: [HealthMetricSnapshot] {
    let snapshots = HomeSnapshotSet(store: healthStore, model: model, selectedDate: selectedDate)
    return [
      snapshots.home(for: .sleep),
      snapshots.home(for: .recovery),
      snapshots.home(for: .strain),
    ]
  }

  private var homeTitle: String {
    ScoreDateTimeline.dateLabel(for: selectedDate)
  }

  private var deviceToolbarTint: Color {
    deviceToolbarConnected ? .green : .red
  }

  private var deviceToolbarAccessibilityValue: String {
    deviceToolbarConnected ? "Connected" : "Disconnected"
  }

  private var deviceToolbarConnected: Bool {
    let state = model.ble.connectionState.lowercased()
    return state == "ready" || state == "connected"
  }

  private var dailyActionSummary: String {
    let inputAction = healthStore.metricInputReadinessNextActionSummary()
    if !inputAction.isEmpty {
      return inputAction
    }
    return healthStore.packetDerivedScoreNextActionSummary()
  }

  private func openHealth(_ route: HealthRoute) {
    openHealthRoute(route)
    model.recordUIAction("health.deep_link.opened", detail: route.title)
  }

  private func openHealthMonitorSnapshot(_ snapshot: HealthMetricSnapshot) {
    if snapshot.id == "resting-hr" {
      selectedHealthMonitorTrend = snapshot
    } else {
      openHealth(.healthMonitor)
    }
  }

  private func openCoach(_ prompt: String) {
    router.openCoach(prompt: prompt)
    model.recordUIAction("coach.opened", detail: "Home daily score card")
  }
}

/// Every card on Home reads from the same landing snapshot set. Deriving that set costs a full
/// walk of today's heart-rate samples, so it is built once per body pass and shared, rather than
/// recomputed per card.
private struct HomeSnapshotSet {
  private let store: HealthDataStore
  private let landingSnapshots: [HealthMetricSnapshot]
  private let selectedDate: Date

  @MainActor
  init(store: HealthDataStore, model: GooseAppModel, selectedDate: Date) {
    self.store = store
    self.selectedDate = selectedDate
    landingSnapshots = store.landingSnapshots(
      liveHeartRateBPM: model.ble.liveHeartRateBPM,
      liveHeartRateSource: model.ble.liveHeartRateSource,
      liveHeartRateUpdatedAt: model.ble.liveHeartRateUpdatedAt,
      stableDailyMetrics: true
    )
  }

  @MainActor
  var scores: [HealthMetricSnapshot] {
    [HealthRoute.sleep, .recovery, .strain].map {
      ScoreDateTimeline.datedSnapshot(from: home(for: $0), date: selectedDate)
    }
  }

  @MainActor
  func landing(for route: HealthRoute) -> HealthMetricSnapshot {
    landingSnapshots.first { $0.route == route } ?? store.snapshot(for: route)
  }

  @MainActor
  func home(for route: HealthRoute) -> HealthMetricSnapshot {
    Self.homeSnapshot(from: landing(for: route), route: route)
  }

  /// Strain arrives on a 0-21 scale; Home shows every score as a percentage.
  private static func homeSnapshot(
    from snapshot: HealthMetricSnapshot,
    route: HealthRoute
  ) -> HealthMetricSnapshot {
    guard route == .strain, snapshot.unit != "%" else {
      return snapshot
    }
    let rawValue = firstNumber(in: snapshot.displayValue) ?? firstNumber(in: snapshot.value) ?? 0
    let percent = min(max(Int((rawValue / 21 * 100).rounded()), 0), 100)
    return HealthMetricSnapshot(
      id: snapshot.id,
      route: snapshot.route,
      group: snapshot.group,
      title: snapshot.title,
      value: "\(percent)",
      unit: "%",
      status: snapshot.status,
      freshness: snapshot.freshness,
      provenance: snapshot.provenance,
      source: snapshot.source,
      systemImage: snapshot.systemImage,
      tint: snapshot.tint,
      trend: snapshot.trend
    )
  }
}


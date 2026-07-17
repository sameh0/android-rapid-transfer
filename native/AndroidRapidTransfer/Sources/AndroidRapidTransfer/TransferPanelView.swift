import AndroidRapidTransferCore
import SwiftUI

struct TransferPanelView: View {
    @Bindable var model: TransferViewModel
    @State private var selectedTab = TransferPanelTab.activity
    @State private var isChoosingDestination = false
    @State private var isExecuting = false
    /// Bumped whenever new jobs join the list, to fly a file into the header.
    @State private var launchCount = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Copies", selection: $selectedTab) {
                    Text("Activity")
                        .tag(TransferPanelTab.activity)
                    Text(model.copyQueue.isEmpty ? "Queue" : "Queue \(model.copyQueue.count)")
                        .tag(TransferPanelTab.queue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Copies panel section")
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)

            switch selectedTab {
            case .activity:
                TransferActivityHeaderView(
                    rows: model.rows,
                    overall: model.overallProgress,
                    summary: model.lastSessionSummary,
                    isExpanded: model.isPanelExpanded,
                    toggle: togglePanel,
                    stopAll: stopAll,
                    clearSettled: clearSettled
                )
            case .queue:
                CopyQueueHeaderView(
                    queue: model.copyQueue,
                    isExpanded: model.isPanelExpanded,
                    toggle: togglePanel
                )
            }

            if model.isPanelExpanded {
                Group {
                    Divider()
                    switch selectedTab {
                    case .activity:
                        activityList
                    case .queue:
                        queueList
                    }
                }
                .motionTransition(Motion.panelSlide)
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .topLeading) {
            TransferLaunchToken(trigger: launchCount)
        }
        .destinationImporter(isPresented: $isChoosingDestination, onPick: execute)
        .onAppear {
            // The panel appears together with its first job.
            if model.rows.contains(where: { !$0.state.isTerminal }) { launchCount += 1 }
        }
        .onChange(of: model.rows.count) { oldCount, newCount in
            if newCount > oldCount { launchCount += 1 }
        }
    }

    // MARK: - Lists

    private var activityList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.rows) { row in
                    VStack(spacing: 0) {
                        TransferPanelRowView(
                            row: row,
                            cancel: { cancel(row.id) },
                            dismiss: { dismiss(row.id) },
                            retry: model.canRetry(row) ? { retry(row.id) } : nil
                        )
                        if row.id != model.rows.last?.id {
                            Divider()
                        }
                    }
                    .motionTransition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                    ))
                }
            }
            .motion(Motion.bouncy, value: model.rows.map(\.id))
        }
        .frame(maxHeight: 260)
    }

    @ViewBuilder
    private var queueList: some View {
        if model.copyQueue.isEmpty {
            ContentUnavailableView(
                "Queue is Empty",
                systemImage: "tray",
                description: Text(
                    "Copy items in one pane (⌘C, or ⇧⌘C to add), then paste them into the other pane (⌘V)."
                )
            )
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.copyQueue.items) { item in
                        VStack(spacing: 0) {
                            CopyQueueRowView(
                                item: item,
                                remove: { removeFromQueue(item.id) }
                            )
                            if item.id != model.copyQueue.items.last?.id {
                                Divider()
                            }
                        }
                        .motionTransition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity.combined(with: .move(edge: .leading))
                        ))
                    }
                }
                .motion(Motion.snappy, value: model.copyQueue.items.map(\.id))
            }
            .frame(maxHeight: 260)
        }
        Divider()
        CopyQueueFooterView(
            queue: model.copyQueue,
            canExecute: model.canExecuteCopyQueue,
            isExecuting: isExecuting,
            clear: { withMotion(Motion.snappy) { model.copyQueue.removeAll() } },
            execute: { isChoosingDestination = true }
        )
    }

    // MARK: - Actions

    private func togglePanel() {
        withMotion(Motion.gentle) { model.togglePanel() }
    }

    private func cancel(_ id: UUID) {
        Task { await model.cancel(jobID: id) }
    }

    private func dismiss(_ id: UUID) {
        withMotion(Motion.snappy) { model.dismiss(jobID: id) }
    }

    private func clearSettled() {
        withMotion(Motion.snappy) { model.dismissSettled() }
    }

    private func retry(_ id: UUID) {
        Task { await model.retry(jobID: id) }
    }

    private func removeFromQueue(_ id: CopyQueueItem.ID) {
        withMotion(Motion.snappy) { model.copyQueue.remove(id: id) }
    }

    private func stopAll() {
        Task { await model.stopAll() }
    }

    /// Transfers outlive this call, so a future sandbox security scope must be held for the batch lifetime.
    private func execute(to destination: URL) {
        isExecuting = true
        Task {
            defer {
                isExecuting = false
            }
            if await model.executeCopyQueue(destination: destination) {
                withMotion(Motion.gentle) {
                    selectedTab = .activity
                    model.isPanelExpanded = true
                }
            }
        }
    }
}

/// A file that swoops down from the panes above into the panel's progress
/// ring each time a copy is queued, so starting a copy visibly "sends"
/// something. Invisible at rest and skipped under Reduce Motion.
struct TransferLaunchToken: View {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the header's ring sits, relative to the panel's top leading
    /// corner: the tab row (8 + 22 pt) then the header's padding and half the
    /// ring.
    private nonisolated static let ringCenter = CGPoint(x: 16 + 15, y: 30 + 8 + 15)

    var body: some View {
        if !reduceMotion {
            GeometryReader { proxy in
                let start = CGPoint(x: proxy.size.width * 0.5, y: -90)
                Image(systemName: "doc.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(Color.accentColor.gradient, in: .rect(cornerRadius: Radius.row, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    .keyframeAnimator(initialValue: LaunchFrame(), trigger: trigger) { token, frame in
                        token
                            .scaleEffect(frame.scale)
                            .opacity(frame.opacity)
                            .position(
                                x: start.x + (Self.ringCenter.x - start.x) * frame.travel,
                                // A shallow arc: the token lifts a little before diving.
                                y: start.y + (Self.ringCenter.y - start.y) * frame.travel
                                    - sin(frame.travel * .pi) * 40
                            )
                    } keyframes: { _ in
                        KeyframeTrack(\.travel) {
                            MoveKeyframe(0)
                            CubicKeyframe(1, duration: 0.55)
                        }
                        KeyframeTrack(\.scale) {
                            MoveKeyframe(1.15)
                            CubicKeyframe(1, duration: 0.2)
                            CubicKeyframe(0.35, duration: 0.35)
                        }
                        KeyframeTrack(\.opacity) {
                            MoveKeyframe(0)
                            LinearKeyframe(1, duration: 0.1)
                            LinearKeyframe(1, duration: 0.35)
                            LinearKeyframe(0, duration: 0.1)
                        }
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private struct LaunchFrame {
        var travel: CGFloat = 1
        var scale: CGFloat = 0.35
        var opacity: Double = 0
    }
}

import AutomationRuntime
import EngineCore
import Memory
import SwiftUI

/// InspectorCallRecoverySection lets the person review one worker's unresolved actions and acknowledge
/// them individually. It appends history through the runtime; no action is repeated or declared successful.
struct InspectorCallRecoverySection: View {
    let team: TeamModel
    let worker: WorkerSnapshot

    @State private var reviews: [CallRecoveryReview] = []
    @State private var problem: String?
    @State private var isReading = true
    @State private var isShowingReview = false
    @State private var selected: CallRecoveryReview?
    @State private var isConfirming = false
    @State private var isSaving = false

    private struct Key: Equatable {
        let worker: UUID
        let revision: Int
        let running: Bool
    }

    private var memory: MemoryService {
        MemoryService.shared(for: KnowledgeLocation.knowledge(under: WorkspaceLaunch.directory))
    }
    private var streamID: String { "worker-" + worker.id.uuidString }
    private var isRunning: Bool { team.isAnswering(worker.id) }

    var body: some View {
        Section("Actions to Review") {
            if isReading {
                Text("Reading actions…").foregroundStyle(.secondary)
            } else if reviews.isEmpty, problem == nil {
                Text("No unresolved actions").foregroundStyle(.secondary)
            } else {
                Button("Review Unresolved Actions…") { isShowingReview = true }
                if let problem { Text(problem).foregroundStyle(.secondary) }
            }
        }
        .task(id: Key(worker: worker.id, revision: team.transcriptRevision, running: isRunning)) {
            await read()
        }
        .sheet(isPresented: $isShowingReview) { reviewSheet }
    }

    private var reviewSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Actions to Review").font(.title2)
                Spacer()
                Button("Done") { isShowingReview = false }.keyboardShortcut(.cancelAction)
            }
            Text("Check the application's current state before allowing this worker to continue.")
                .foregroundStyle(.secondary)
            if isRunning {
                Text("Stop the worker's response before acknowledging an action.")
                    .foregroundStyle(.secondary)
            }
            if let problem { Text(problem).foregroundStyle(.secondary).textSelection(.enabled) }
            if reviews.isEmpty {
                Text("No unresolved actions").foregroundStyle(.secondary)
            } else {
                List(reviews) { review in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.title(review.call.request)).font(.headline)
                        Text(Date(timeIntervalSince1970: Double(review.call.event.occurredAtMS) / 1000), style: .date)
                            .foregroundStyle(.secondary)
                        Text(Date(timeIntervalSince1970: Double(review.call.event.occurredAtMS) / 1000), style: .time)
                            .foregroundStyle(.secondary)
                        if case .error(let message)? = review.call.progress.result {
                            Text(message).font(.caption).textSelection(.enabled)
                        }
                        if !review.canAcknowledge {
                            Text("This action has no confirmed end yet. Stop the worker and refresh the list.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Acknowledge Outcome…") {
                            selected = review
                            isConfirming = true
                        }
                        .disabled(isRunning || isSaving || !review.canAcknowledge)
                    }
                    .padding(.vertical, 8)
                }
                .frame(minHeight: 180, maxHeight: 420)
            }
            Button("Refresh") { Task { await read() } }.disabled(isSaving)
        }
        .padding(24)
        .frame(width: 540)
        .confirmationDialog("Acknowledge this action?", isPresented: $isConfirming, presenting: selected) { review in
            Button("Allow Further Actions") { Task { await acknowledge(review) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Confirm that this action has stopped and you have reviewed its outcome. The worker can send new actions afterward. This does not repeat the action or mark it successful.")
        }
    }

    private func read() async {
        do {
            let loaded = try await memory.callsRequiringReview(source: .app, streamID: streamID)
            guard !Task.isCancelled else { return }
            reviews = loaded
            problem = nil
        } catch {
            guard !Task.isCancelled else { return }
            problem = MemoryService.describe(error)
        }
        isReading = false
    }

    private func acknowledge(_ review: CallRecoveryReview) async {
        guard !isRunning, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await memory.acknowledgeUnresolvedCall(review.id, source: .app, streamID: streamID)
            await read()
        } catch CallRecoveryError.stillRunning {
            problem = String(localized: "This action may still be running. Stop the worker and try again.")
        } catch CallRecoveryError.notUnresolved {
            await read()
        } catch CallRecoveryError.differentProducer {
            problem = String(localized: "The action belongs to a different worker.")
        } catch {
            problem = MemoryService.describe(error)
        }
    }

    private static func title(_ request: AgentCallRequest) -> String {
        switch request {
        case .appCall(let app, let verb, _): "\(app).\(verb)"
        default: String(localized: "Action")
        }
    }
}

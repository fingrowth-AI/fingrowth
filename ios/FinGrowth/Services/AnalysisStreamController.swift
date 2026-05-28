import Foundation
import Observation

// Observable bridge between APIClient.streamAnalysis and SwiftUI views.
//
// SwiftUI doesn't speak AsyncThrowingStream directly, so the controller owns
// the consuming Task and projects each event onto plain @Observable state.
// Cancellation propagates through the Task -> AsyncThrowingStream
// onTermination handler, which tears down the underlying URL session task in
// APIClient.

@MainActor
@Observable
final class AnalysisStreamController {
    enum Phase: Equatable {
        case idle
        case running(stage: String)
        case completed
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle
    private(set) var stages: [String] = []
    private(set) var research: ResearchData?
    private(set) var partialAnalysis: AnalysisData?
    private(set) var finalResult: AnalysisResponse?
    private(set) var errorMessage: String?

    private let client: APIClient
    private var streamingTask: Task<Void, Never>?

    init(client: APIClient) {
        self.client = client
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func start(query: AnalysisQuery, profile: PortfolioProfile? = nil) {
        cancel()
        reset()
        phase = .running(stage: "starting")

        let stream = client.streamAnalysis(query: query, profile: profile)
        streamingTask = Task { [weak self] in
            await self?.consume(stream: stream)
        }
    }

    func cancel() {
        streamingTask?.cancel()
        streamingTask = nil
    }

    // Cancel any in-flight stream and clear the displayed results back to idle.
    // Unlike `cancel()`, this also wipes the last run's research/analysis/final
    // state so a follow-up that never contacts the cloud (e.g. a .localOnly
    // route) doesn't leave stale results on screen.
    func clear() {
        cancel()
        reset()
        phase = .idle
    }

    private func reset() {
        stages = []
        research = nil
        partialAnalysis = nil
        finalResult = nil
        errorMessage = nil
    }

    private func consume(stream: AsyncThrowingStream<AnalysisEvent, Error>) async {
        do {
            for try await event in stream {
                if Task.isCancelled { return }
                apply(event)
            }
            // Stream ended cleanly. If we never saw a final_result the server
            // closed the connection early — treat that as idle rather than an
            // error so a user-initiated cancel reads as expected.
            if finalResult == nil, case .running = phase {
                phase = .idle
            }
        } catch is CancellationError {
            phase = .idle
        } catch let error as APIClientError {
            failed(with: error.errorDescription ?? "Network error.")
        } catch {
            failed(with: error.localizedDescription)
        }
    }

    private func apply(_ event: AnalysisEvent) {
        switch event {
        case .progress(let stage):
            stages.append(stage)
            phase = .running(stage: stage)
        case .partialResearch(let data):
            research = data
        case .partialAnalysis(let technical, let confidence):
            partialAnalysis = AnalysisData(
                technical: technical,
                narrative: "",
                confidence: confidence
            )
        case .finalResult(let response):
            finalResult = response
            phase = .completed
        case .serverError(let message):
            failed(with: message)
        }
    }

    private func failed(with message: String) {
        errorMessage = message
        phase = .failed(message: message)
    }
}

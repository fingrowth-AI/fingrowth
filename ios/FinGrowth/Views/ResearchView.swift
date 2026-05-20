import SwiftUI

// Stopgap research surface for P4-02. Exercises APIClient.streamAnalysis so
// the acceptance criteria for SSE consumption ("Stream displays progress
// updates in UI", "Network error shows user-friendly message", "Request
// cancellation closes SSE connection") are verifiable end-to-end. P4-03
// replaces this with the polished query interface (ticker autocomplete,
// formatted sections, "Test with paper trade") and will keep the same
// AnalysisStreamController.
struct ResearchView: View {
    let apiClient: APIClient

    @State private var controller: AnalysisStreamController?
    @State private var query: String = ""
    @State private var ticker: String = ""
    @State private var analysisType: AnalysisType = .technical

    var body: some View {
        NavigationStack {
            Form {
                querySection
                if let controller {
                    stageSection(controller: controller)
                    resultsSection(controller: controller)
                    if let message = controller.errorMessage {
                        errorSection(message: message)
                    }
                }
            }
            .navigationTitle("Research")
            .onAppear { ensureController() }
        }
    }

    private var querySection: some View {
        Section {
            TextField("Ask a question", text: $query, axis: .vertical)
                .lineLimit(2...4)
            TextField("Ticker (e.g. AAPL)", text: $ticker)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Picker("Type", selection: $analysisType) {
                ForEach(AnalysisType.allCases) { type in
                    Text(type.rawValue.capitalized).tag(type)
                }
            }
            HStack {
                Button("Run analysis") { run() }
                    .disabled(!canSubmit)
                Spacer()
                if controller?.isRunning == true {
                    Button("Cancel", role: .destructive) {
                        controller?.cancel()
                    }
                }
            }
        } header: {
            Text("Query")
        } footer: {
            Text("Streams from the backend configured in Settings.")
        }
    }

    private func stageSection(controller: AnalysisStreamController) -> some View {
        Section {
            switch controller.phase {
            case .idle:
                Text("No active request.").foregroundStyle(.secondary)
            case .running(let stage):
                Label("Stage: \(stage.capitalized)", systemImage: "ellipsis.circle")
            case .completed:
                Label("Completed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if !controller.stages.isEmpty {
                Text("Progress: " + controller.stages.joined(separator: " → "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Progress")
        }
    }

    @ViewBuilder
    private func resultsSection(controller: AnalysisStreamController) -> some View {
        if let final = controller.finalResult {
            Section {
                Text(final.analysis.narrative.isEmpty
                     ? "(no narrative)"
                     : final.analysis.narrative)
                Text("Confidence: \(final.analysis.confidence)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(final.disclaimer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Result · \(final.ticker)")
            }
        } else if let partial = controller.partialAnalysis {
            Section {
                Text("Confidence: \(partial.confidence)")
                Text("Indicators: \(partial.technical.keys.sorted().joined(separator: ", "))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Partial analysis")
            }
        } else if let research = controller.research {
            Section {
                Text("Filings: \(research.filings.count)")
                Text("News: \(research.news.count)")
            } header: {
                Text("Research")
            }
        }
    }

    private func errorSection(message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        } header: {
            Text("Error")
        }
    }

    private var canSubmit: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
            && !ticker.trimmingCharacters(in: .whitespaces).isEmpty
            && controller?.isRunning != true
    }

    private func ensureController() {
        if controller == nil {
            controller = AnalysisStreamController(client: apiClient)
        }
    }

    private func run() {
        ensureController()
        let request = AnalysisQuery(
            query: query.trimmingCharacters(in: .whitespaces),
            ticker: ticker.trimmingCharacters(in: .whitespaces).uppercased(),
            analysisType: analysisType
        )
        controller?.start(query: request)
    }
}

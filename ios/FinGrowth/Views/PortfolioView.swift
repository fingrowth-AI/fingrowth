import SwiftUI

// Stopgap Portfolio surface until P4-04 lands the full Holdings / Performance
// split. For P4-03 we need a placeholder order form that "Test with paper
// trade" can populate so the acceptance criterion ("'Test with paper trade'
// pre-fills order form with relevant ticker") is verifiable end-to-end.
struct PortfolioView: View {
    let paperTradePrefill: PaperTradePrefill

    @State private var ticker: String = ""
    // Intentionally optional / unset: this is a research tool, not an advisor,
    // so we don't pre-pick a direction (buy vs. sell) for the user.
    @State private var side: PaperOrderSide?
    @State private var quantity: String = "1"
    @State private var sourceNote: String = ""
    @State private var lastSubmitted: String?

    enum PaperOrderSide: String, CaseIterable, Identifiable {
        case buy, sell
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ticker", text: $ticker)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Picker("Side", selection: $side) {
                        Text("Select").tag(PaperOrderSide?.none)
                        ForEach(PaperOrderSide.allCases) { value in
                            Text(value.rawValue.capitalized).tag(PaperOrderSide?.some(value))
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("Quantity", text: $quantity)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Paper trade")
                } footer: {
                    Text("Paper trade routing lands in P4-04. This form captures the prefill from Research.")
                }

                if !sourceNote.isEmpty {
                    Section("From research") {
                        Text(sourceNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        guard let side else { return }
                        lastSubmitted = "\(side.rawValue.uppercased()) \(quantity) \(ticker)"
                    } label: {
                        Label("Submit paper trade", systemImage: "paperplane.fill")
                    }
                    .disabled(ticker.trimmingCharacters(in: .whitespaces).isEmpty
                              || Int(quantity) == nil
                              || side == nil)
                }

                if let lastSubmitted {
                    Section("Last simulated order") {
                        Text(lastSubmitted).monospaced()
                    }
                }
            }
            .navigationTitle("Portfolio")
            .onAppear(perform: applyPrefill)
            .onChange(of: paperTradePrefill.pending) { _, _ in applyPrefill() }
        }
    }

    private func applyPrefill() {
        guard let pending = paperTradePrefill.consume() else { return }
        ticker = pending.ticker
        sourceNote = "\"\(pending.sourceQuery)\" · "
            + pending.sourceAnalysisType.rawValue.capitalized
            + " · confidence: \(pending.sourceConfidence)"
    }
}

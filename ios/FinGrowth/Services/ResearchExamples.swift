import Foundation

// V12-05: example queries offered next to the query box, so a new user isn't
// staring at a blank field. They span the analysis paths the auto-classifier
// (V12-04) recognizes — technical, fundamental, portfolio-level, and general —
// so tapping one both seeds a good question and shows what the app can do.
//
// Single-ticker examples carry their ticker so tapping one fills the ticker
// field too — otherwise Run would stay disabled (canSubmit needs a ticker for a
// non-portfolio query). Portfolio-level examples leave it nil.
struct ResearchExample: Identifiable, Equatable {
    let query: String
    let ticker: String?

    var id: String { query }
}

enum ResearchExamples {
    static let all: [ResearchExample] = [
        ResearchExample(query: "Is AAPL overbought right now?", ticker: "AAPL"),
        ResearchExample(query: "How were NVDA's latest earnings?", ticker: "NVDA"),
        ResearchExample(query: "Is my portfolio too concentrated?", ticker: nil),
        ResearchExample(query: "What's the latest news on TSLA?", ticker: "TSLA"),
    ]
}

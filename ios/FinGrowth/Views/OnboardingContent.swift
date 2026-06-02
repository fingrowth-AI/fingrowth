import Foundation

// V12-05: first-run onboarding content.
//
// Three pages, in order, covering exactly what the acceptance criterion calls
// for: the privacy model, the research-not-advice framing, and portfolio import.
// Kept as data (separate from the view) so the coverage is unit-testable.
struct OnboardingPage: Identifiable, Equatable {
    enum Topic: String, CaseIterable { case privacy, framing, csvImport }

    let topic: Topic
    let systemImage: String
    let title: String
    let body: String

    var id: String { topic.rawValue }
}

enum OnboardingContent {
    static let pages: [OnboardingPage] = [
        OnboardingPage(
            topic: .privacy,
            systemImage: "lock.shield.fill",
            title: "Your data stays on your device",
            body: "FinGrowth processes your portfolio on-device. Your raw brokerage rows, "
                + "account numbers, and name never leave your phone. Cloud analysis sees only "
                + "generalized, query-relevant context — and the Privacy tab logs exactly what "
                + "was shared, every time."
        ),
        OnboardingPage(
            topic: .framing,
            systemImage: "doc.text.magnifyingglass",
            title: "Research, not advice",
            body: "This is a research tool. It explains what the signals mean and how they "
                + "fit your portfolio, but it never tells you to buy or sell — those "
                + "decisions, and the responsibility for them, stay yours."
        ),
        OnboardingPage(
            topic: .csvImport,
            systemImage: "square.and.arrow.down.fill",
            title: "Import your portfolio",
            body: "In the Portfolio tab, import a Fidelity, Schwab, Vanguard, or Robinhood CSV. "
                + "It's parsed entirely on-device, so the raw rows never leave your phone — and "
                + "your research becomes personalized to what you actually hold."
        ),
    ]
}

import Foundation

// V12-01: validation for the paper-trade order form.
//
// Pulled out of the SwiftUI view so the rules an order must satisfy before it
// can be placed are directly unit-testable. Two of them encode the design's
// acceptance criteria:
//   * A side must be explicitly chosen — the toggle starts unselected, so the
//     decision (and the responsibility for it) stays the user's, keeping the
//     app on the right side of the advice line.
//   * A non-empty thesis is required — the user writes *why* before placing the
//     order, which is what gives the research-to-outcome loop substance.
enum PaperOrderForm {
    /// Whether an order may be placed. All four must hold: a ticker, an
    /// explicitly chosen side, a positive quantity, and a non-blank thesis.
    static func canPlace(
        ticker: String,
        sideSelected: Bool,
        quantity: Double?,
        thesis: String
    ) -> Bool {
        !ticker.trimmingCharacters(in: .whitespaces).isEmpty
            && sideSelected
            && (quantity ?? 0) > 0
            && hasThesis(thesis)
    }

    /// A thesis counts only when it has non-whitespace content.
    static func hasThesis(_ thesis: String) -> Bool {
        !thesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

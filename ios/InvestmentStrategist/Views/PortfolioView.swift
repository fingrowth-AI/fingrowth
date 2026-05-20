import SwiftUI

struct PortfolioView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Portfolio",
                systemImage: "chart.line.uptrend.xyaxis",
                description: Text("Holdings and paper trades arrive in P4-04.")
            )
            .navigationTitle("Portfolio")
        }
    }
}

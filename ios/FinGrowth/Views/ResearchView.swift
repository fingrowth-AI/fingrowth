import SwiftUI

struct ResearchView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Research",
                systemImage: "magnifyingglass",
                description: Text("Query interface arrives in P4-03.")
            )
            .navigationTitle("Research")
        }
    }
}

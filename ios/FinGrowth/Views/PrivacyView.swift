import SwiftUI

struct PrivacyView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Privacy Audit",
                systemImage: "lock.shield",
                description: Text("Audit log arrives once outbound transmissions exist.")
            )
            .navigationTitle("Privacy")
        }
    }
}

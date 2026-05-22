import SwiftUI

struct PrivacyView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                MarketBackground()
                VStack(spacing: 18) {
                    GlassPanel {
                        VStack(alignment: .leading, spacing: 14) {
                            Image(systemName: "lock.shield.fill")
                                .font(.largeTitle.weight(.semibold))
                                .foregroundStyle(FinTheme.accent)
                                .frame(width: 56, height: 56)
                                .background(FinTheme.accent.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                            Text("Privacy Audit")
                                .font(.largeTitle.weight(.bold))
                            Text("Outbound transmission logs will appear here once research requests are shared with cloud analysis services.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                privacyPill("Raw ledger stays local", systemImage: "iphone.gen3")
                                privacyPill("Only anonymized profile", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                    }
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Privacy")
        }
    }
}

private func privacyPill(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(FinTheme.mint.opacity(0.12))
        .foregroundStyle(FinTheme.mint)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
}

import SwiftUI

// V12-05: first-run onboarding. A simple paged walkthrough of the privacy
// model, the research-not-advice framing, and portfolio import. Dismissing it
// (Get started / final page) flips AppSettings.hasSeenOnboarding so it never
// reappears.
struct OnboardingView: View {
    @Bindable var settings: AppSettings
    @State private var page = 0

    private let pages = OnboardingContent.pages

    var body: some View {
        ZStack {
            MarketBackground()
            VStack(spacing: 20) {
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, item in
                        pageView(item).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                Button(action: advance) {
                    Text(page == pages.count - 1 ? "Get started" : "Next")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)

                Button("Skip") { finish() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 32)
        }
    }

    private func pageView(_ item: OnboardingPage) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: item.systemImage)
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(FinTheme.accent)
                .frame(width: 96, height: 96)
                .background(FinTheme.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            Text(item.title)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Text(item.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private func advance() {
        if page < pages.count - 1 {
            withAnimation { page += 1 }
        } else {
            finish()
        }
    }

    private func finish() {
        settings.hasSeenOnboarding = true
    }
}

import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var gemma: GemmaService
    @Bindable var authCoordinator: AuthCoordinator
    let sessionStore: SessionStore

    var body: some View {
        NavigationStack {
            ZStack {
                MarketBackground()
                Form {
                    AccountSectionView(
                        coordinator: authCoordinator,
                        sessionStore: sessionStore
                    )

                    Section {
                        Picker("Appearance", selection: $settings.appearance) {
                            ForEach(AppAppearance.allCases) { appearance in
                                Text(appearance.title).tag(appearance)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Display")
                    } footer: {
                        Text("Choose a fixed theme or follow the device setting.")
                    }

                    Section {
                        TextField("Backend URL", text: $settings.backendURL)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
                        Button("Reset to default") {
                            settings.resetBackendURL()
                        }
                    } header: {
                        Text("Backend")
                    } footer: {
                        Text("Cloud agents reachable at this URL. Persists across restarts.")
                    }

                    Section {
                        Toggle("Enable on-device model", isOn: $settings.onDeviceModelEnabled)
                        GemmaModelStatusView(gemma: gemma)
                    } header: {
                        Text("On-device intelligence")
                    } footer: {
                        Text("Gemma 4 runs entirely on this device for PII parsing and query rewriting. Enabling it downloads the model once (~2.5GB), then caches it.")
                    }

                    Section {
                        Picker("Shared portfolio detail", selection: $settings.portfolioPrivacyLevel) {
                            ForEach(PortfolioPrivacyLevel.allCases) { level in
                                Text(level.title).tag(level)
                            }
                        }
                        Text(settings.portfolioPrivacyLevel.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Cloud privacy")
                    } footer: {
                        Text("Controls how much generalized portfolio context leaves the device. Raw holdings never do.")
                    }

                    Section {
                        Label {
                            Text("This is a research tool, not financial advice. Always verify before acting.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "exclamationmark.shield")
                                .foregroundStyle(FinTheme.amber)
                        }
                    } header: {
                        Text("Disclaimer")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
        }
    }
}

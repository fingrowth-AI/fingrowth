import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        NavigationStack {
            ZStack {
                MarketBackground()
                Form {
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

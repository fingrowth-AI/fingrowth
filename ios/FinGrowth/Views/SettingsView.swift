import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("This is a research tool, not financial advice. Always verify before acting.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Disclaimer")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

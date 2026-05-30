import AuthenticationServices
import SwiftUI

// V8-01: Settings section for Sign in with Apple. Shows the native sign-in
// button when signed out and the signed-in identity (with sign-out) otherwise.
struct AccountSectionView: View {
    @Bindable var coordinator: AuthCoordinator
    let sessionStore: SessionStore

    var body: some View {
        Section {
            if sessionStore.isSignedIn {
                signedInRow
                Button("Sign out", role: .destructive) {
                    coordinator.signOut()
                }
            } else {
                SignInWithAppleButton(.signIn) { request in
                    coordinator.configure(request)
                } onCompletion: { result in
                    Task { await coordinator.handle(result) }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 44)
                .disabled(coordinator.isAuthenticating)
                .opacity(coordinator.isAuthenticating ? 0.5 : 1)

                if coordinator.isAuthenticating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Signing in…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            if let error = coordinator.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Account")
        } footer: {
            Text(sessionStore.isSignedIn
                 ? "Your trades and research are tied to your account. Sign in with Apple never shares your real email unless you choose to."
                 : "Sign in with Apple to keep your portfolio and paper trades private to you across devices.")
        }
    }

    private var signedInRow: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Signed in with Apple")
                    .font(.subheadline.weight(.medium))
                if let userID = sessionStore.userID {
                    Text("ID \(userID.prefix(8))…")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(FinTheme.mint)
        }
    }
}

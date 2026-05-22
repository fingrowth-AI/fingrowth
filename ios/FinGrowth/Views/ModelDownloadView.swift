import SwiftUI

// On-device model status + download control (P5-01). Designed to sit inside the
// Settings Form. Observes GemmaService's published state and offers a download /
// retry action. The progress bar appears on first launch while the ~2.5GB GGUF
// is fetched; once cached it never re-downloads, so this collapses to "Ready".
struct GemmaModelStatusView: View {
    @Bindable var gemma: GemmaService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("On-device model", systemImage: statusIcon)
                    .foregroundStyle(statusColor)
                Spacer()
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if case .downloading(let fraction) = gemma.state {
                ProgressView(value: fraction)
                Text("\(Int(fraction * 100))% downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .loading = gemma.state {
                ProgressView()
            }

            if case .failed(let message) = gemma.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if showsActionButton {
                Button(actionTitle) {
                    Task { await gemma.prepare() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }

    private var showsActionButton: Bool {
        switch gemma.state {
        case .notReady, .failed: return true
        case .downloading, .loading, .ready: return false
        }
    }

    private var actionTitle: String {
        if case .failed = gemma.state { return "Retry download" }
        return "Download model"
    }

    private var statusText: String {
        switch gemma.state {
        case .notReady: return "Not downloaded"
        case .downloading: return "Downloading…"
        case .loading: return "Loading…"
        // Distinguish a loaded 2.5GB Gemma from the development stub so "Ready"
        // is never mistaken for the real model during development.
        case .ready: return gemma.usesRealModel ? "Ready" : "Ready (development stub)"
        case .failed: return "Unavailable"
        }
    }

    private var statusIcon: String {
        switch gemma.state {
        case .ready: return "cpu.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "cpu"
        }
    }

    private var statusColor: Color {
        switch gemma.state {
        case .ready: return .green
        case .failed: return .red
        default: return .primary
        }
    }
}

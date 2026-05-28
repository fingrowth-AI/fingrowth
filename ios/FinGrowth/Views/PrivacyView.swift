import SwiftUI
import SwiftData

// Privacy tab (P5-06). Shows the device-only audit log in reverse-chronological
// order: every query prepared for the cloud, what was redacted, and what was
// actually sent. Tapping an entry opens a side-by-side original-vs-sent detail.
// The log can be exported as JSON; it is never transmitted.
struct PrivacyView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AuditEntry.timestamp, order: .reverse)
    private var allEntries: [AuditEntry]

    private var entries: [AuditEntry] { allEntries.filter(\.isPrivacyEntry) }

    var body: some View {
        NavigationStack {
            ZStack {
                MarketBackground()
                if entries.isEmpty {
                    emptyState
                } else {
                    auditList
                }
            }
            .navigationTitle("Privacy")
            .toolbar {
                if let url = exportedFileURL {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }

    private var auditList: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    NavigationLink {
                        AuditDetailView(entry: entry)
                    } label: {
                        AuditRow(entry: entry)
                    }
                }
            } footer: {
                Text("Logged on-device only. This audit log is never sent to the cloud.")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
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
                    Text("Each research request you run will appear here, showing exactly what was shared with cloud analysis and what stayed on your device.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding()
    }

    // Writes the exported JSON to a temp file for the share sheet. Returns nil
    // when there's nothing to export.
    private var exportedFileURL: URL? {
        guard !entries.isEmpty,
              let data = try? PrivacyAuditLog(context: modelContext).exportJSON() else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "fingrowth-privacy-audit.json")
        try? data.write(to: url)
        return url
    }
}

private struct AuditRow: View {
    let entry: AuditEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.originalQuery ?? "—")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(entry.timestamp, style: .date)
                Text(entry.timestamp, style: .time)
                Spacer()
                if entry.substitutions.isEmpty {
                    Label("No PII", systemImage: "checkmark.shield")
                        .foregroundStyle(FinTheme.mint)
                } else {
                    Label("\(entry.substitutions.count) redacted", systemImage: "eye.slash")
                        .foregroundStyle(FinTheme.amber)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct AuditDetailView: View {
    let entry: AuditEntry

    var body: some View {
        List {
            Section("Original vs. sent") {
                HStack(alignment: .top, spacing: 12) {
                    column(title: "You asked", text: entry.originalQuery ?? "—", tint: .primary)
                    Divider()
                    column(title: "Sent to cloud", text: entry.rewrittenQuery ?? "—", tint: FinTheme.accent)
                }
            }

            if !entry.substitutions.isEmpty {
                Section("Redactions") {
                    ForEach(Array(entry.substitutions.enumerated()), id: \.offset) { _, sub in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(sub.original)
                                    .strikethrough()
                                    .foregroundStyle(FinTheme.danger)
                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(sub.replacement)
                                    .foregroundStyle(FinTheme.accent)
                            }
                            .font(.subheadline)
                            Text(sub.type.rawValue)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(FinTheme.amber.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Details") {
                detailRow("PII detected", entry.piiDetected.isEmpty ? "None" : entry.piiDetected.joined(separator: ", "))
                if let level = entry.generalizationLevel {
                    detailRow("Portfolio generalization", level.capitalized)
                }
                if let confidence = entry.confidenceScore {
                    detailRow("Confidence", String(format: "%.0f%%", confidence * 100))
                }
                detailRow("Endpoint", entry.endpoint)
            }
        }
        .navigationTitle("Audit Detail")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func column(title: String, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

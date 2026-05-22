import Foundation

// On-device PII detection for CSV imports (P5-03).
//
// The privacy boundary is enforced at ingestion: the parser separates a full
// PrivateLedger (device-only, includes PII like account numbers / holder
// names) from an anonymized ShareableProfile. This file produces the PIIReport
// — an auditable record of every PII field detected, with type and confidence,
// and never the raw value in full.
//
// Two strategies sit behind PIIExtracting: a deterministic heuristic detector
// (the P4-05-style fallback that also runs in the simulator/tests with zero
// network) and a Gemma-powered detector for non-standard headers. Per the
// design, the Gemma path falls back to the heuristic on any failure.

struct PIIFinding: Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case accountNumber
        case holderName
        case ssn
        case email
        case phone

        var label: String {
            switch self {
            case .accountNumber: return "Account number"
            case .holderName: return "Account holder"
            case .ssn: return "SSN"
            case .email: return "Email"
            case .phone: return "Phone"
            }
        }
    }

    let kind: Kind
    /// Masked rendering — never the full raw value (so the report itself is safe
    /// to surface in UI / audit logs).
    let maskedValue: String
    let confidence: Double  // 0...1
    /// Where it was found (column header or "metadata").
    let context: String
}

struct PIIReport: Equatable, Sendable {
    var findings: [PIIFinding]

    static let empty = PIIReport(findings: [])

    var containsPII: Bool { !findings.isEmpty }

    func findings(of kind: PIIFinding.Kind) -> [PIIFinding] {
        findings.filter { $0.kind == kind }
    }
}

protocol PIIExtracting: Sendable {
    func extractPII(rows: [[String]], headers: [String]) async -> PIIReport
}

// MARK: - Heuristic extractor (deterministic; fallback + dev/test path)

struct HeuristicPIIExtractor: PIIExtracting, Sendable {
    func extractPII(rows: [[String]], headers: [String]) async -> PIIReport {
        detect(rows: rows, headers: headers)
    }

    // Synchronous core so the legacy sync parse path can reuse it.
    func detect(rows: [[String]], headers: [String]) -> PIIReport {
        var findings: [PIIFinding] = []
        let normalized = headers.map(Self.normalize)
        let dataRows = rows.dropFirst()  // assume first row is the header

        // 1. Label-driven detection: a column whose header names a PII field.
        for (index, header) in normalized.enumerated() {
            guard let (kind, confidence) = Self.labeledKind(for: header) else { continue }
            guard let value = firstNonEmptyValue(in: dataRows, column: index) else { continue }
            findings.append(PIIFinding(
                kind: kind,
                maskedValue: Self.mask(value, kind: kind),
                confidence: confidence,
                context: headers[index]
            ))
        }

        // 2. Value-pattern detection for anything the labels missed (e.g. an
        // SSN or email sitting in a generically-named column or metadata).
        var seenKinds = Set(findings.map(\.kind))
        for row in rows {
            for value in row {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let kind = Self.patternKind(for: trimmed), !seenKinds.contains(kind) {
                    findings.append(PIIFinding(
                        kind: kind,
                        maskedValue: Self.mask(trimmed, kind: kind),
                        confidence: Self.patternConfidence(kind),
                        context: "value"
                    ))
                    seenKinds.insert(kind)
                }
            }
        }

        return PIIReport(findings: findings)
    }

    private func firstNonEmptyValue(in rows: ArraySlice<[String]>, column: Int) -> String? {
        for row in rows where row.indices.contains(column) {
            let value = row[column].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: Detection rules

    static func normalize(_ header: String) -> String {
        header.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" && $0 != "." && $0 != "#" }
    }

    // Specific holder labels only — deliberately excludes "name"/"accountname"
    // so a Fidelity "Account Name = INDIVIDUAL" column isn't read as a person.
    private static let accountNumberHeaders: Set<String> = [
        "accountnumber", "acctnumber", "accountno", "acctno", "accountnum",
    ]
    private static let holderHeaders: Set<String> = [
        "accountholder", "accountholdername", "holdername", "holder",
        "registrationname", "accountowner", "ownername",
    ]
    private static let ssnHeaders: Set<String> = ["ssn", "socialsecurity", "socialsecuritynumber", "taxid"]
    private static let emailHeaders: Set<String> = ["email", "emailaddress"]
    private static let phoneHeaders: Set<String> = ["phone", "phonenumber", "telephone"]

    private static func labeledKind(for header: String) -> (PIIFinding.Kind, Double)? {
        if accountNumberHeaders.contains(header) { return (.accountNumber, 0.95) }
        if holderHeaders.contains(header) { return (.holderName, 0.95) }
        if ssnHeaders.contains(header) { return (.ssn, 0.97) }
        if emailHeaders.contains(header) { return (.email, 0.95) }
        if phoneHeaders.contains(header) { return (.phone, 0.92) }
        return nil
    }

    private static func patternKind(for value: String) -> PIIFinding.Kind? {
        if value.range(of: #"^\d{3}-\d{2}-\d{4}$"#, options: .regularExpression) != nil { return .ssn }
        if value.range(of: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil { return .email }
        return nil
    }

    private static func patternConfidence(_ kind: PIIFinding.Kind) -> Double {
        switch kind {
        case .ssn: return 0.97
        case .email: return 0.95
        default: return 0.8
        }
    }

    // MARK: Masking — never expose the full value

    static func mask(_ value: String, kind: PIIFinding.Kind) -> String {
        switch kind {
        case .accountNumber:
            let last4 = String(value.suffix(4))
            return "••••\(last4)"
        case .holderName:
            return value
                .split(separator: " ")
                .map { token -> String in
                    guard let first = token.first else { return "" }
                    return token.count <= 1 ? String(first) : "\(first)\(String(repeating: "•", count: token.count - 1))"
                }
                .joined(separator: " ")
        case .ssn:
            return "•••-••-\(value.suffix(4))"
        case .email:
            guard let at = value.firstIndex(of: "@"), let first = value.first else { return "•••" }
            return "\(first)•••\(value[at...])"
        case .phone:
            return "•••-•••-\(value.suffix(4))"
        }
    }
}

// MARK: - Gemma-powered extractor (real on-device path)

// Uses the on-device model to classify column semantics — catching PII in
// non-standard headers a fixed rule set would miss — and falls back to the
// heuristic detector when the model isn't ready or inference fails. Only the
// real model adds value here; with the development stub this resolves to the
// heuristic result, which is exactly the design's required fallback.
struct GemmaPIIExtractor: PIIExtracting {
    let gemma: GemmaService
    let fallback = HeuristicPIIExtractor()

    func extractPII(rows: [[String]], headers: [String]) async -> PIIReport {
        let baseline = fallback.detect(rows: rows, headers: headers)
        // Only attempt model enrichment when a real model is actually loaded;
        // otherwise the deterministic baseline is the answer.
        guard await gemma.usesRealModel, await gemma.isReady else { return baseline }

        var byKind = Dictionary(grouping: baseline.findings, by: \.kind)
        let dataRows = Array(rows.dropFirst())
        for (index, header) in headers.enumerated() {
            guard let sample = dataRows.first(where: { $0.indices.contains(index) })?[index],
                  !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let category = await gemma.classify(
                prompt: "Column header: \"\(header)\". Example value: \"\(sample)\".",
                categories: ["account_number", "holder_name", "ssn", "email", "phone", "none"]
            )
            guard let kind = Self.kind(from: category), byKind[kind] == nil else { continue }
            byKind[kind] = [PIIFinding(
                kind: kind,
                maskedValue: HeuristicPIIExtractor.mask(sample, kind: kind),
                confidence: 0.9,
                context: header
            )]
        }
        return PIIReport(findings: byKind.values.flatMap { $0 })
    }

    private static func kind(from category: String) -> PIIFinding.Kind? {
        switch category {
        case "account_number": return .accountNumber
        case "holder_name": return .holderName
        case "ssn": return .ssn
        case "email": return .email
        case "phone": return .phone
        default: return nil
        }
    }
}

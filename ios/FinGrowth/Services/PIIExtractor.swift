import Foundation

// On-device PII detection for CSV imports (P5-03).
//
// The privacy boundary is enforced at ingestion: the parser separates a full
// PrivateLedger (device-only, includes PII like account numbers / holder
// names) from an anonymized ShareableProfile. This file produces both the
// PIIReport — an auditable record of every PII field detected, with type and
// confidence, and never the raw value in full — and the raw identity fields the
// device-only ledger needs.
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

// The report plus the raw identity fields (account number / holder name) that
// belong ONLY on the device-only PrivateLedger. Raw values never enter the
// report; the report only ever holds masked renderings.
struct PIIExtractionResult: Equatable, Sendable {
    var report: PIIReport
    var accountNumber: String?
    var accountHolder: String?

    static let empty = PIIExtractionResult(report: .empty, accountNumber: nil, accountHolder: nil)
}

protocol PIIExtracting: Sendable {
    func extract(
        headers: [String],
        dataRows: [[String]],
        metadataRows: [[String]]
    ) async -> PIIExtractionResult
}

// MARK: - Heuristic extractor (deterministic; fallback + dev/test path)

struct HeuristicPIIExtractor: PIIExtracting, Sendable {
    func extract(
        headers: [String],
        dataRows: [[String]],
        metadataRows: [[String]]
    ) async -> PIIExtractionResult {
        detect(headers: headers, dataRows: dataRows, metadataRows: metadataRows)
    }

    // Synchronous core so the legacy sync parse path can reuse it.
    func detect(
        headers: [String],
        dataRows: [[String]],
        metadataRows: [[String]] = []
    ) -> PIIExtractionResult {
        var findings: [PIIFinding] = []
        var seenKinds = Set<PIIFinding.Kind>()
        var accountNumber: String?
        var accountHolder: String?

        func record(kind: PIIFinding.Kind, rawValue: String, confidence: Double, context: String) {
            guard !seenKinds.contains(kind) else { return }
            seenKinds.insert(kind)
            findings.append(PIIFinding(
                kind: kind,
                maskedValue: Self.mask(rawValue, kind: kind),
                confidence: confidence,
                context: context
            ))
            if kind == .accountNumber, accountNumber == nil { accountNumber = rawValue }
            if kind == .holderName, accountHolder == nil { accountHolder = rawValue }
        }

        // 1. Labeled columns: a header that names a PII field.
        let normalizedHeaders = headers.map(Self.normalize)
        for (index, header) in normalizedHeaders.enumerated() {
            guard let (kind, confidence) = Self.labeledKind(for: header) else { continue }
            guard let value = firstNonEmptyValue(in: dataRows, column: index) else { continue }
            record(kind: kind, rawValue: value, confidence: confidence, context: headers[index])
        }

        // 2. Metadata key-value lines above the table (e.g. "Account Holder: John A. Smith").
        for row in metadataRows {
            guard let (label, value) = Self.metadataKeyValue(row),
                  let (kind, confidence) = Self.labeledKind(for: label) else { continue }
            record(kind: kind, rawValue: value, confidence: confidence, context: "metadata")
        }

        // 3. Value-pattern detection (SSN / email) across metadata + data, for
        // anything the labels missed.
        for row in metadataRows + dataRows {
            for value in row {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let kind = Self.patternKind(for: trimmed) else { continue }
                record(kind: kind, rawValue: trimmed, confidence: Self.patternConfidence(kind), context: "value")
            }
        }

        return PIIExtractionResult(
            report: PIIReport(findings: findings),
            accountNumber: accountNumber,
            accountHolder: accountHolder
        )
    }

    private func firstNonEmptyValue(in rows: [[String]], column: Int) -> String? {
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

    // Parse a metadata row into (normalized label, raw value): either a
    // two-cell row ["Account Holder","John A. Smith"] or a single cell with a
    // colon ("Account Holder: John A. Smith").
    static func metadataKeyValue(_ row: [String]) -> (label: String, value: String)? {
        if row.count >= 2 {
            let label = normalize(row[0])
            let value = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty, !value.isEmpty { return (label, value) }
        }
        if row.count == 1, let colon = row[0].firstIndex(of: ":") {
            let label = normalize(String(row[0][..<colon]))
            let value = String(row[0][row[0].index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty, !value.isEmpty { return (label, value) }
        }
        return nil
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
        case .accountNumber, .ssn, .phone:
            return maskKeepingSuffix(value, suffix: 4)
        case .holderName:
            return value
                .split(separator: " ")
                .map { token -> String in
                    guard let first = token.first else { return "" }
                    return token.count <= 1 ? String(first) : "\(first)\(String(repeating: "•", count: token.count - 1))"
                }
                .joined(separator: " ")
        case .email:
            guard let at = value.firstIndex(of: "@"), let first = value.first else { return "•••" }
            return "\(first)•••\(value[at...])"
        }
    }

    // Reveal the trailing `suffix` characters only when doing so still hides the
    // majority of the value; short values are masked entirely so a 2-char
    // account number can't leak through "last 4".
    static func maskKeepingSuffix(_ value: String, suffix: Int) -> String {
        let count = value.count
        guard count > 0 else { return "" }
        let reveal = count >= suffix * 2 ? suffix : 0
        let hidden = String(repeating: "•", count: max(count - reveal, 1))
        guard reveal > 0 else { return hidden }
        return hidden + value.suffix(reveal)
    }
}

// MARK: - Gemma-powered extractor (real on-device path)

// Uses the on-device model to classify column semantics — catching PII in
// non-standard headers a fixed rule set would miss — and falls back to the
// heuristic detector when the model isn't ready or inference fails. A failed or
// undetermined classification yields "" (never a guessed category), so failure
// degrades to the heuristic result rather than fabricating findings.
struct GemmaPIIExtractor: PIIExtracting {
    let gemma: GemmaService
    let fallback = HeuristicPIIExtractor()

    func extract(
        headers: [String],
        dataRows: [[String]],
        metadataRows: [[String]]
    ) async -> PIIExtractionResult {
        var result = fallback.detect(headers: headers, dataRows: dataRows, metadataRows: metadataRows)
        // Only enrich when a real model is actually loaded; otherwise the
        // deterministic baseline is the answer.
        guard await gemma.usesRealModel, await gemma.isReady else { return result }

        var byKind = Dictionary(grouping: result.report.findings, by: \.kind)
        for (index, header) in headers.enumerated() {
            guard let sample = firstSample(in: dataRows, column: index) else { continue }
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
            // Non-standard columns the heuristic missed still populate the
            // device-only ledger identity.
            if kind == .accountNumber, result.accountNumber == nil { result.accountNumber = sample }
            if kind == .holderName, result.accountHolder == nil { result.accountHolder = sample }
        }
        result.report = PIIReport(findings: byKind.values.flatMap { $0 })
        return result
    }

    private func firstSample(in rows: [[String]], column: Int) -> String? {
        for row in rows where row.indices.contains(column) {
            let value = row[column].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
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

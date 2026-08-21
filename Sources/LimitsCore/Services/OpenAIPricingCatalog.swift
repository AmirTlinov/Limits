import CryptoKit
import Foundation
import LimitsShared

public enum OpenAIPricingCatalogError: LocalizedError, Equatable {
    case disallowedSource(String)
    case invalidHTTPStatus(Int)
    case invalidContentType(String)
    case responseTooLarge(Int)
    case missingTable(String)
    case invalidHeader(String)
    case incompleteModels([String])
    case invalidNumber(String)

    public var errorDescription: String? {
        switch self {
        case .disallowedSource(let source): return L10n.tr("pricing.error.disallowed_source", source)
        case .invalidHTTPStatus(let status): return L10n.tr("pricing.error.http_status", status)
        case .invalidContentType(let type): return L10n.tr("pricing.error.content_type", type)
        case .responseTooLarge(let bytes): return L10n.tr("pricing.error.response_too_large", bytes)
        case .missingTable(let name): return L10n.tr("pricing.error.missing_table", name)
        case .invalidHeader(let header): return L10n.tr("pricing.error.invalid_header", header)
        case .incompleteModels(let models): return L10n.tr("pricing.error.incomplete_models", models.joined(separator: ", "))
        case .invalidNumber(let value): return L10n.tr("pricing.error.invalid_number", value)
        }
    }
}

public struct OpenAIPricingDownload: Sendable {
    public let data: Data
    public let statusCode: Int
    public let mimeType: String?
    public let finalURL: URL

    public init(data: Data, statusCode: Int, mimeType: String?, finalURL: URL) {
        self.data = data
        self.statusCode = statusCode
        self.mimeType = mimeType
        self.finalURL = finalURL
    }
}

public protocol OpenAIPricingDownloading: Sendable {
    func download(_ url: URL) async throws -> OpenAIPricingDownload
}

public struct URLSessionOpenAIPricingDownloader: OpenAIPricingDownloading {
    public init() {}

    public func download(_ url: URL) async throws -> OpenAIPricingDownload {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData
        request.timeoutInterval = 20
        request.setValue("text/markdown,text/plain;q=0.9", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else {
            throw OpenAIPricingCatalogError.invalidHTTPStatus(0)
        }
        if http.expectedContentLength > Int64(OpenAIPricingCatalog.maximumResponseBytes) {
            throw OpenAIPricingCatalogError.responseTooLarge(Int(http.expectedContentLength))
        }
        var data = Data()
        data.reserveCapacity(max(0, min(Int(http.expectedContentLength), OpenAIPricingCatalog.maximumResponseBytes)))
        for try await byte in bytes {
            guard data.count < OpenAIPricingCatalog.maximumResponseBytes else {
                throw OpenAIPricingCatalogError.responseTooLarge(data.count + 1)
            }
            data.append(byte)
        }
        return OpenAIPricingDownload(
            data: data,
            statusCode: http.statusCode,
            mimeType: http.mimeType,
            finalURL: finalURL
        )
    }
}

public struct OpenAIPricingRefreshResult: Sendable {
    public let revision: OpenAIRateCardRevision
    public let priceChange: OpenAIPriceChange?
    public let error: String?
    public let fetched: Bool

    public init(revision: OpenAIRateCardRevision, priceChange: OpenAIPriceChange?, error: String?, fetched: Bool) {
        self.revision = revision
        self.priceChange = priceChange
        self.error = error
        self.fetched = fetched
    }
}

public actor OpenAIPricingCatalog {
    public static let refreshInterval: TimeInterval = 24 * 60 * 60
    public static let maximumResponseBytes = 1_000_000
    public static let chatGPTRateCardURL = URL(string: "https://learn.chatgpt.com/docs/pricing.md")!
    public static let APIRateCardURL = URL(string: "https://developers.openai.com/api/docs/pricing.md")!
    public static let speedRateCardURL = URL(string: "https://learn.chatgpt.com/docs/agent-configuration/speed.md")!

    private let repository: CodexUsageRepository
    private let downloader: any OpenAIPricingDownloading

    public init(
        repository: CodexUsageRepository,
        downloader: any OpenAIPricingDownloading = URLSessionOpenAIPricingDownloader()
    ) {
        self.repository = repository
        self.downloader = downloader
    }

    public func refreshIfNeeded(now: Date = .now, force: Bool = false) async -> OpenAIPricingRefreshResult {
        let existing = (try? await repository.snapshot().rateCardRevisions.last) ?? Self.bundledRevision
        if !force, now.timeIntervalSince(existing.lastCheckedAt) >= 0,
           now.timeIntervalSince(existing.lastCheckedAt) < Self.refreshInterval {
            return OpenAIPricingRefreshResult(revision: existing, priceChange: nil, error: nil, fetched: false)
        }

        do {
            async let chatGPTDownload = downloader.download(Self.chatGPTRateCardURL)
            async let apiDownload = downloader.download(Self.APIRateCardURL)
            async let speedDownload = downloader.download(Self.speedRateCardURL)
            let (chatGPT, api, speed) = try await (chatGPTDownload, apiDownload, speedDownload)
            try Self.validate(chatGPT, expected: Self.chatGPTRateCardURL)
            try Self.validate(api, expected: Self.APIRateCardURL)
            try Self.validate(speed, expected: Self.speedRateCardURL)
            guard let chatGPTText = String(data: chatGPT.data, encoding: .utf8),
                  let apiText = String(data: api.data, encoding: .utf8),
                  let speedText = String(data: speed.data, encoding: .utf8) else {
                throw OpenAIPricingCatalogError.invalidContentType("utf-8")
            }
            let parsed = try OpenAIPricingParser.parse(
                chatGPTMarkdown: chatGPTText,
                apiMarkdown: apiText,
                speedMarkdown: speedText,
                observedAt: now
            )
            let revision = OpenAIRateCardRevision(
                id: parsed.id,
                observedAt: parsed.id == existing.id ? existing.observedAt : parsed.observedAt,
                checkedAt: now,
                sourceHashes: parsed.sourceHashes,
                rates: parsed.rates
            )
            let inserted = try await repository.recordRateCardRevision(revision)
            let change = inserted ? Self.priceChange(previous: existing, current: revision) : nil
            return OpenAIPricingRefreshResult(revision: revision, priceChange: change, error: nil, fetched: true)
        } catch {
            let fallback = OpenAIRateCardRevision(
                id: existing.id,
                observedAt: existing.observedAt,
                checkedAt: now,
                sourceHashes: existing.sourceHashes,
                rates: existing.rates
            )
            _ = try? await repository.recordRateCardRevision(fallback)
            return OpenAIPricingRefreshResult(
                revision: fallback,
                priceChange: nil,
                error: error.localizedDescription,
                fetched: false
            )
        }
    }

    private static func validate(_ response: OpenAIPricingDownload, expected: URL) throws {
        guard response.statusCode == 200 else { throw OpenAIPricingCatalogError.invalidHTTPStatus(response.statusCode) }
        guard response.data.count <= maximumResponseBytes else {
            throw OpenAIPricingCatalogError.responseTooLarge(response.data.count)
        }
        guard response.finalURL.scheme == "https",
              response.finalURL.host == expected.host,
              response.finalURL.path == expected.path else {
            throw OpenAIPricingCatalogError.disallowedSource(response.finalURL.absoluteString)
        }
        let mime = response.mimeType?.lowercased() ?? ""
        guard ["text/markdown", "text/plain", "text/x-markdown"].contains(mime) else {
            throw OpenAIPricingCatalogError.invalidContentType(mime)
        }
    }

    private static func priceChange(
        previous: OpenAIRateCardRevision?,
        current: OpenAIRateCardRevision
    ) -> OpenAIPriceChange? {
        guard let previous, previous.id != current.id else { return nil }

        func multiplied(_ base: Decimal?, by multiplier: Decimal?) -> Decimal? {
            guard let base, let multiplier else { return nil }
            return base * multiplier
        }

        func cacheWriteBase(_ rate: OpenAIModelRate) -> Decimal? {
            rate.usdPerMillionCacheWrite ?? rate.usdPerMillionInput
        }

        func cacheWriteTier(
            _ rate: OpenAIModelRate,
            explicitMultiplier: Decimal?,
            inputMultiplier: Decimal?
        ) -> Decimal? {
            multiplied(
                cacheWriteBase(rate),
                by: rate.usdPerMillionCacheWrite == nil ? inputMultiplier : explicitMultiplier
            )
        }

        var winner: (String, OpenAIPriceMetric, Decimal, Decimal, Decimal)?
        for model in current.rates.keys.sorted() {
            guard let old = previous.rates[model], let new = current.rates[model] else { continue }
            let pairs: [(OpenAIPriceMetric, Decimal?, Decimal?)] = [
                (.creditsInput, old.creditsPerMillionInput, new.creditsPerMillionInput),
                (.creditsCachedInput, old.creditsPerMillionCachedInput, new.creditsPerMillionCachedInput),
                (.creditsOutput, old.creditsPerMillionOutput, new.creditsPerMillionOutput),
                (.creditsFastMultiplier, old.creditsFastMultiplier, new.creditsFastMultiplier),
                (.apiInput, old.usdPerMillionInput, new.usdPerMillionInput),
                (.apiCachedInput, old.usdPerMillionCachedInput, new.usdPerMillionCachedInput),
                (.apiCacheWrite, cacheWriteBase(old), cacheWriteBase(new)),
                (.apiOutput, old.usdPerMillionOutput, new.usdPerMillionOutput),
                (
                    .apiLongInput,
                    multiplied(old.usdPerMillionInput, by: old.longContextInputMultiplier),
                    multiplied(new.usdPerMillionInput, by: new.longContextInputMultiplier)
                ),
                (
                    .apiLongCachedInput,
                    multiplied(old.usdPerMillionCachedInput, by: old.longContextCachedInputMultiplier),
                    multiplied(new.usdPerMillionCachedInput, by: new.longContextCachedInputMultiplier)
                ),
                (
                    .apiLongCacheWrite,
                    cacheWriteTier(
                        old,
                        explicitMultiplier: old.longContextCacheWriteMultiplier,
                        inputMultiplier: old.longContextInputMultiplier
                    ),
                    cacheWriteTier(
                        new,
                        explicitMultiplier: new.longContextCacheWriteMultiplier,
                        inputMultiplier: new.longContextInputMultiplier
                    )
                ),
                (
                    .apiLongOutput,
                    multiplied(old.usdPerMillionOutput, by: old.longContextOutputMultiplier),
                    multiplied(new.usdPerMillionOutput, by: new.longContextOutputMultiplier)
                ),
                (
                    .apiFastInput,
                    multiplied(old.usdPerMillionInput, by: old.fastInputMultiplier),
                    multiplied(new.usdPerMillionInput, by: new.fastInputMultiplier)
                ),
                (
                    .apiFastCachedInput,
                    multiplied(old.usdPerMillionCachedInput, by: old.fastCachedInputMultiplier),
                    multiplied(new.usdPerMillionCachedInput, by: new.fastCachedInputMultiplier)
                ),
                (
                    .apiFastCacheWrite,
                    cacheWriteTier(
                        old,
                        explicitMultiplier: old.fastCacheWriteMultiplier,
                        inputMultiplier: old.fastInputMultiplier
                    ),
                    cacheWriteTier(
                        new,
                        explicitMultiplier: new.fastCacheWriteMultiplier,
                        inputMultiplier: new.fastInputMultiplier
                    )
                ),
                (
                    .apiFastOutput,
                    multiplied(old.usdPerMillionOutput, by: old.fastOutputMultiplier),
                    multiplied(new.usdPerMillionOutput, by: new.fastOutputMultiplier)
                ),
                (
                    .apiFastLongInput,
                    multiplied(old.usdPerMillionInput, by: old.fastLongContextInputMultiplier),
                    multiplied(new.usdPerMillionInput, by: new.fastLongContextInputMultiplier)
                ),
                (
                    .apiFastLongCachedInput,
                    multiplied(old.usdPerMillionCachedInput, by: old.fastLongContextCachedInputMultiplier),
                    multiplied(new.usdPerMillionCachedInput, by: new.fastLongContextCachedInputMultiplier)
                ),
                (
                    .apiFastLongCacheWrite,
                    cacheWriteTier(
                        old,
                        explicitMultiplier: old.fastLongContextCacheWriteMultiplier,
                        inputMultiplier: old.fastLongContextInputMultiplier
                    ),
                    cacheWriteTier(
                        new,
                        explicitMultiplier: new.fastLongContextCacheWriteMultiplier,
                        inputMultiplier: new.fastLongContextInputMultiplier
                    )
                ),
                (
                    .apiFastLongOutput,
                    multiplied(old.usdPerMillionOutput, by: old.fastLongContextOutputMultiplier),
                    multiplied(new.usdPerMillionOutput, by: new.fastLongContextOutputMultiplier)
                ),
            ]
            for (metric, oldValue, newValue) in pairs {
                guard let oldValue, let newValue, oldValue != 0, oldValue != newValue else { continue }
                let change = abs((newValue - oldValue) / oldValue * 100)
                if winner == nil || change > winner!.4 { winner = (model, metric, oldValue, newValue, change) }
            }
        }
        guard let winner else { return nil }
        return OpenAIPriceChange(
            modelID: winner.0,
            metric: winner.1,
            previousRevisionID: previous.id,
            currentRevisionID: current.id,
            previousValue: winner.2,
            currentValue: winner.3,
            maximumPercentChange: winner.4
        )
    }

    public static let bundledRevision: OpenAIRateCardRevision = {
        let rates = OpenAIPricingParser.bundledRates
        return OpenAIRateCardRevision(
            id: "bundled-2026-08-21",
            observedAt: .distantPast,
            checkedAt: .distantPast,
            sourceHashes: ["bundled": "2026-08-21"],
            rates: Dictionary(uniqueKeysWithValues: rates.map { ($0.modelID, $0) })
        )
    }()
}

public enum OpenAIPricingParser {
    public static let requiredModels = [
        "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini",
    ]

    public static func parse(
        chatGPTMarkdown: String,
        apiMarkdown: String,
        speedMarkdown: String,
        observedAt: Date
    ) throws -> OpenAIRateCardRevision {
        let credits = try parseChatGPTCredits(chatGPTMarkdown)
        let creditFastMultipliers = try parseCreditFastMultipliers(speedMarkdown)
        let standard = try parseAPITable(apiMarkdown, heading: "### Standard pricing data")
        let fast = try parseAPITable(apiMarkdown, heading: "### Fast pricing data")
        let missing = requiredModels.filter { credits[$0] == nil || standard[$0] == nil }
        guard missing.isEmpty else { throw OpenAIPricingCatalogError.incompleteModels(missing) }

        var rates: [String: OpenAIModelRate] = [:]
        for model in requiredModels {
            let credit = credits[model]!
            let api = standard[model]!
            let fastRate = fast[model]
            rates[model] = OpenAIModelRate(
                modelID: model,
                creditsPerMillionInput: credit.input,
                creditsPerMillionCachedInput: credit.cached,
                creditsPerMillionOutput: credit.output,
                usdPerMillionInput: api.input,
                usdPerMillionCachedInput: api.cached,
                usdPerMillionCacheWrite: api.cacheWrite,
                usdPerMillionOutput: api.output,
                longContextThreshold: api.longInput == nil ? nil : 272_000,
                longContextInputMultiplier: ratio(api.longInput, api.input),
                longContextCachedInputMultiplier: ratio(api.longCached, api.cached),
                longContextCacheWriteMultiplier: ratio(api.longCacheWrite, api.cacheWrite),
                longContextOutputMultiplier: ratio(api.longOutput, api.output),
                creditsFastMultiplier: creditFastMultipliers[model],
                fastInputMultiplier: ratio(fastRate?.input, api.input),
                fastCachedInputMultiplier: ratio(fastRate?.cached, api.cached),
                fastCacheWriteMultiplier: ratio(fastRate?.cacheWrite, api.cacheWrite),
                fastOutputMultiplier: ratio(fastRate?.output, api.output),
                fastLongContextInputMultiplier: ratio(fastRate?.longInput, api.input),
                fastLongContextCachedInputMultiplier: ratio(fastRate?.longCached, api.cached),
                fastLongContextCacheWriteMultiplier: ratio(fastRate?.longCacheWrite, api.cacheWrite),
                fastLongContextOutputMultiplier: ratio(fastRate?.longOutput, api.output)
            )
        }
        let chatHash = sha256(chatGPTMarkdown)
        let apiHash = sha256(apiMarkdown)
        let speedHash = sha256(speedMarkdown)
        let revisionID = sha256("\(chatHash)|\(apiHash)|\(speedHash)")
        return OpenAIRateCardRevision(
            id: revisionID,
            observedAt: observedAt,
            checkedAt: observedAt,
            sourceHashes: ["chatgpt": chatHash, "api": apiHash, "speed": speedHash],
            rates: rates
        )
    }

    public static let bundledRates: [OpenAIModelRate] = [
        rate("gpt-5.6-sol", 125, 12.5, 750, 5, 0.5, 6.25, 30, longInput: 10, longCached: 1, longCacheWrite: 12.5, longOutput: 45, creditFast: 2.5, fastInput: 10, fastCached: 1, fastCacheWrite: 12.5, fastOutput: 60, fastLongInput: 20, fastLongCached: 2, fastLongCacheWrite: 25, fastLongOutput: 90),
        rate("gpt-5.6-terra", 50, 5, 300, 2, 0.2, 2.5, 12, longInput: 4, longCached: 0.4, longCacheWrite: 5, longOutput: 18, creditFast: 2.5, fastInput: 4, fastCached: 0.4, fastCacheWrite: 5, fastOutput: 24, fastLongInput: 8, fastLongCached: 0.8, fastLongCacheWrite: 10, fastLongOutput: 36),
        rate("gpt-5.6-luna", 5, 0.5, 30, 0.2, 0.02, 0.25, 1.2, longInput: 0.4, longCached: 0.04, longCacheWrite: 0.5, longOutput: 1.8, creditFast: 2.5, fastInput: 0.4, fastCached: 0.04, fastCacheWrite: 0.5, fastOutput: 2.4, fastLongInput: 0.8, fastLongCached: 0.08, fastLongCacheWrite: 1, fastLongOutput: 3.6),
        rate("gpt-5.5", 125, 12.5, 750, 5, 0.5, nil, 30, longInput: 10, longCached: 1, longCacheWrite: nil, longOutput: 45, creditFast: 2.5, fastInput: 12.5, fastCached: 1.25, fastCacheWrite: nil, fastOutput: 75),
        rate("gpt-5.4", 62.5, 6.25, 375, 2.5, 0.25, nil, 15, longInput: 5, longCached: 0.5, longCacheWrite: nil, longOutput: 22.5, creditFast: 2, fastInput: 5, fastCached: 0.5, fastCacheWrite: nil, fastOutput: 30),
        rate("gpt-5.4-mini", 18.75, 1.875, 113, 0.75, 0.075, nil, 4.5, longInput: nil, longCached: nil, longCacheWrite: nil, longOutput: nil, creditFast: nil, fastInput: 1.5, fastCached: 0.15, fastCacheWrite: nil, fastOutput: 9),
    ]

    private struct Triple { let input: Decimal; let cached: Decimal; let output: Decimal }
    private struct APIRow {
        let input: Decimal
        let cached: Decimal?
        let cacheWrite: Decimal?
        let output: Decimal
        let longInput: Decimal?
        let longCached: Decimal?
        let longCacheWrite: Decimal?
        let longOutput: Decimal?
    }

    private static func parseCreditFastMultipliers(_ markdown: String) throws -> [String: Decimal] {
        func multiplier(_ pattern: String) throws -> Decimal {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
            guard let match = regex.firstMatch(in: markdown, range: range),
                  let valueRange = Range(match.range(at: 1), in: markdown) else {
                throw OpenAIPricingCatalogError.missingTable("ChatGPT speed rates")
            }
            return try number(String(markdown[valueRange]))
        }
        let frontier = try multiplier("GPT-5\\.6 and GPT-5\\.5 consume credits at ([0-9.]+)x")
        let previous = try multiplier("GPT-5\\.4 consumes credits at ([0-9.]+)x")
        guard frontier >= 1, previous >= 1 else {
            throw OpenAIPricingCatalogError.invalidNumber("ChatGPT speed multiplier")
        }
        return [
            "gpt-5.6-sol": frontier,
            "gpt-5.6-terra": frontier,
            "gpt-5.6-luna": frontier,
            "gpt-5.5": frontier,
            "gpt-5.4": previous,
        ]
    }

    private static func parseChatGPTCredits(_ markdown: String) throws -> [String: Triple] {
        guard let marker = markdown.range(of: "Credits per 1M tokens"),
              let end = markdown.range(of: "</table>", range: marker.lowerBound..<markdown.endIndex) else {
            throw OpenAIPricingCatalogError.missingTable("ChatGPT credits")
        }
        let table = String(markdown[marker.lowerBound..<end.upperBound])
        let rowRegex = try NSRegularExpression(pattern: "<tr[^>]*>([\\s\\S]*?)</tr>", options: [.caseInsensitive])
        let cellRegex = try NSRegularExpression(pattern: "<t[dh][^>]*>([\\s\\S]*?)</t[dh]>", options: [.caseInsensitive])
        let range = NSRange(table.startIndex..<table.endIndex, in: table)
        var result: [String: Triple] = [:]
        for match in rowRegex.matches(in: table, range: range) {
            guard let rowRange = Range(match.range(at: 1), in: table) else { continue }
            let row = String(table[rowRange])
            let cells = cellRegex.matches(in: row, range: NSRange(row.startIndex..<row.endIndex, in: row)).compactMap { match -> String? in
                guard let valueRange = Range(match.range(at: 1), in: row) else { return nil }
                return plainText(String(row[valueRange]))
            }
            guard cells.count == 4, let model = canonicalModel(cells[0]), requiredModels.contains(model) else { continue }
            result[model] = Triple(
                input: try number(cells[1]),
                cached: try number(cells[2]),
                output: try number(cells[3])
            )
        }
        return result
    }

    private static func parseAPITable(_ markdown: String, heading: String) throws -> [String: APIRow] {
        guard let headingRange = markdown.range(of: heading) else {
            throw OpenAIPricingCatalogError.missingTable(heading)
        }
        let suffix = markdown[headingRange.upperBound...]
        let sectionEnd = suffix.range(of: "\n### ")?.lowerBound ?? markdown.endIndex
        let lines = markdown[headingRange.upperBound..<sectionEnd].split(separator: "\n").map(String.init)
        guard let header = lines.first(where: { $0.hasPrefix("| Model |") }) else {
            throw OpenAIPricingCatalogError.invalidHeader(heading)
        }
        let headerCells = cells(header)
        let expected = [
            "Model", "Short context input", "Short context cached input", "Short context cache writes",
            "Short context output", "Long context input", "Long context cached input",
            "Long context cache writes", "Long context output",
        ]
        guard headerCells == expected else { throw OpenAIPricingCatalogError.invalidHeader(header) }
        var result: [String: APIRow] = [:]
        for line in lines where line.hasPrefix("|") && !line.contains("---") && line != header {
            let values = cells(line)
            guard values.count == 9, let model = canonicalModel(values[0]), requiredModels.contains(model) else { continue }
            result[model] = APIRow(
                input: try number(values[1]),
                cached: try optionalNumber(values[2]),
                cacheWrite: try optionalNumber(values[3]),
                output: try number(values[4]),
                longInput: try optionalNumber(values[5]),
                longCached: try optionalNumber(values[6]),
                longCacheWrite: try optionalNumber(values[7]),
                longOutput: try optionalNumber(values[8])
            )
        }
        return result
    }

    private static func cells(_ row: String) -> [String] {
        row.split(separator: "|", omittingEmptySubsequences: false)
            .dropFirst().dropLast()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func canonicalModel(_ value: String) -> String? {
        let normalized = value.lowercased()
            .replacingOccurrences(of: "(<272k context length)", with: "")
            .replacingOccurrences(of: "gpt-5.4 mini", with: "gpt-5.4-mini")
            .replacingOccurrences(of: "gpt-5.6 sol", with: "gpt-5.6-sol")
            .replacingOccurrences(of: "gpt-5.6 terra", with: "gpt-5.6-terra")
            .replacingOccurrences(of: "gpt-5.6 luna", with: "gpt-5.6-luna")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.hasPrefix("gpt-") ? normalized : nil
    }

    private static func number(_ value: String) throws -> Decimal {
        guard let result = try optionalNumber(value) else { throw OpenAIPricingCatalogError.invalidNumber(value) }
        return result
    }

    private static func optionalNumber(_ value: String) throws -> Decimal? {
        let cleaned = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "credits", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned == "-" || cleaned.isEmpty { return nil }
        guard let number = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), number >= 0 else {
            throw OpenAIPricingCatalogError.invalidNumber(value)
        }
        return number
    }

    private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ratio(_ numerator: Decimal?, _ denominator: Decimal?) -> Decimal? {
        guard let numerator, let denominator, denominator != 0 else { return nil }
        return numerator / denominator
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func rate(
        _ model: String,
        _ creditInput: Decimal,
        _ creditCached: Decimal,
        _ creditOutput: Decimal,
        _ apiInput: Decimal,
        _ apiCached: Decimal,
        _ cacheWrite: Decimal?,
        _ apiOutput: Decimal,
        longInput: Decimal?,
        longCached: Decimal?,
        longCacheWrite: Decimal?,
        longOutput: Decimal?,
        creditFast: Decimal?,
        fastInput: Decimal?,
        fastCached: Decimal?,
        fastCacheWrite: Decimal?,
        fastOutput: Decimal?,
        fastLongInput: Decimal? = nil,
        fastLongCached: Decimal? = nil,
        fastLongCacheWrite: Decimal? = nil,
        fastLongOutput: Decimal? = nil
    ) -> OpenAIModelRate {
        OpenAIModelRate(
            modelID: model,
            creditsPerMillionInput: creditInput,
            creditsPerMillionCachedInput: creditCached,
            creditsPerMillionOutput: creditOutput,
            usdPerMillionInput: apiInput,
            usdPerMillionCachedInput: apiCached,
            usdPerMillionCacheWrite: cacheWrite,
            usdPerMillionOutput: apiOutput,
            longContextThreshold: longInput == nil ? nil : 272_000,
            longContextInputMultiplier: ratio(longInput, apiInput),
            longContextCachedInputMultiplier: ratio(longCached, apiCached),
            longContextCacheWriteMultiplier: ratio(longCacheWrite, cacheWrite),
            longContextOutputMultiplier: ratio(longOutput, apiOutput),
            creditsFastMultiplier: creditFast,
            fastInputMultiplier: ratio(fastInput, apiInput),
            fastCachedInputMultiplier: ratio(fastCached, apiCached),
            fastCacheWriteMultiplier: ratio(fastCacheWrite, cacheWrite),
            fastOutputMultiplier: ratio(fastOutput, apiOutput),
            fastLongContextInputMultiplier: ratio(fastLongInput, apiInput),
            fastLongContextCachedInputMultiplier: ratio(fastLongCached, apiCached),
            fastLongContextCacheWriteMultiplier: ratio(fastLongCacheWrite, cacheWrite),
            fastLongContextOutputMultiplier: ratio(fastLongOutput, apiOutput)
        )
    }
}

public enum OpenAIRateCardPolicy {
    public static func effectiveRevision(
        at date: Date,
        revisions: [OpenAIRateCardRevision]
    ) -> OpenAIRateCardRevision? {
        let ordered = revisions.sorted { $0.observedAt < $1.observedAt }
        return ordered.last(where: { $0.observedAt <= date }) ?? ordered.first
    }

    public static func contextTier(
        for usage: CodexTokenUsage,
        modelID: String,
        revision: OpenAIRateCardRevision?
    ) -> OpenAIContextTier {
        guard let revision,
              let rate = CodexUsageCostCalculator.resolvedRate(for: modelID, revision: revision) else {
            return .unknown
        }
        guard let threshold = rate.longContextThreshold else { return .standard }
        return usage.inputTokens > threshold ? .long : .standard
    }
}

public enum CodexUsageCostCalculator {
    public static func totals(
        for usage: CodexTokenUsage,
        modelID: String,
        speed: String?,
        contextTier: OpenAIContextTier? = nil,
        revision: OpenAIRateCardRevision
    ) -> CodexUsageTotals {
        guard let rate = resolvedRate(for: modelID, revision: revision) else {
            return CodexUsageTotals(usage: usage, credits: nil, apiEquivalentUSD: nil)
        }
        let isLong: Bool? = switch contextTier {
        case .standard: false
        case .long: true
        case .unknown: rate.longContextThreshold == nil ? false : nil
        case nil: rate.longContextThreshold.map { usage.inputTokens > $0 } ?? false
        }
        let isFast = ["fast", "priority"].contains(speed?.lowercased() ?? "")

        let million = Decimal(1_000_000)
        func cost(_ tokens: Int64, _ price: Decimal?) -> Decimal? {
            if tokens == 0 { return 0 }
            guard let price else { return nil }
            return Decimal(tokens) / million * price
        }
        func creditPrice(_ base: Decimal?) -> Decimal? {
            guard let base else { return nil }
            guard isFast else { return base }
            guard let multiplier = rate.creditsFastMultiplier else { return nil }
            return base * multiplier
        }
        func apiPrice(
            _ base: Decimal?,
            long: Decimal?,
            fast: Decimal?,
            fastLong: Decimal?
        ) -> Decimal? {
            guard let base else { return nil }
            guard let isLong else { return nil }
            switch (isLong, isFast) {
            case (false, false): return base
            case (true, false): return long.map { base * $0 }
            case (false, true): return fast.map { base * $0 }
            case (true, true): return fastLong.map { base * $0 }
            }
        }
        let creditInputPrice = creditPrice(rate.creditsPerMillionInput)
        let creditCachedPrice = creditPrice(rate.creditsPerMillionCachedInput)
        let creditOutputPrice = creditPrice(rate.creditsPerMillionOutput)
        let creditsParts = [
            cost(usage.billableInputTokens + usage.cacheWriteInputTokens, creditInputPrice),
            cost(usage.cachedInputTokens, creditCachedPrice),
            cost(usage.outputTokens, creditOutputPrice),
        ]
        let apiInputPrice = apiPrice(
            rate.usdPerMillionInput,
            long: rate.longContextInputMultiplier,
            fast: rate.fastInputMultiplier,
            fastLong: rate.fastLongContextInputMultiplier
        )
        let apiCachedPrice = apiPrice(
            rate.usdPerMillionCachedInput,
            long: rate.longContextCachedInputMultiplier,
            fast: rate.fastCachedInputMultiplier,
            fastLong: rate.fastLongContextCachedInputMultiplier
        )
        let explicitCacheWritePrice = apiPrice(
            rate.usdPerMillionCacheWrite,
            long: rate.longContextCacheWriteMultiplier,
            fast: rate.fastCacheWriteMultiplier,
            fastLong: rate.fastLongContextCacheWriteMultiplier
        )
        let apiOutputPrice = apiPrice(
            rate.usdPerMillionOutput,
            long: rate.longContextOutputMultiplier,
            fast: rate.fastOutputMultiplier,
            fastLong: rate.fastLongContextOutputMultiplier
        )
        let apiParts = [
            cost(usage.billableInputTokens, apiInputPrice),
            cost(usage.cachedInputTokens, apiCachedPrice),
            cost(usage.cacheWriteInputTokens, rate.usdPerMillionCacheWrite == nil ? apiInputPrice : explicitCacheWritePrice),
            cost(usage.outputTokens, apiOutputPrice),
        ]
        return CodexUsageTotals(
            usage: usage,
            credits: creditsParts.allSatisfy({ $0 != nil }) ? creditsParts.compactMap { $0 }.reduce(0, +) : nil,
            apiEquivalentUSD: apiParts.allSatisfy({ $0 != nil }) ? apiParts.compactMap { $0 }.reduce(0, +) : nil
        )
    }

    public static func resolvedRate(
        for modelID: String,
        revision: OpenAIRateCardRevision
    ) -> OpenAIModelRate? {
        let normalized = modelID.lowercased()
        if let exact = revision.rates[normalized] { return exact }
        if normalized == "gpt-5.6" { return revision.rates["gpt-5.6-sol"] }
        for family in ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4-mini", "gpt-5.4"] {
            if normalized.hasPrefix(family) { return revision.rates[family] }
        }
        return nil
    }
}

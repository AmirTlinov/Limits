import Foundation
import Testing
@testable import LimitsCore

@Test func pricingParserCombinesStrictChatGPTAndAPIStandardTables() throws {
    let revision = try OpenAIPricingParser.parse(
        chatGPTMarkdown: chatGPTPricingFixture(),
        apiMarkdown: apiPricingFixture(),
        speedMarkdown: speedPricingFixture(),
        observedAt: Date(timeIntervalSince1970: 1_000)
    )

    #expect(Set(revision.rates.keys) == Set(OpenAIPricingParser.requiredModels))
    let sol = try #require(revision.rates["gpt-5.6-sol"])
    #expect(sol.creditsPerMillionInput == 125)
    #expect(sol.creditsPerMillionCachedInput == 12.5)
    #expect(sol.creditsPerMillionOutput == 750)
    #expect(sol.usdPerMillionInput == 5)
    #expect(sol.usdPerMillionCacheWrite == 6.25)
    #expect(sol.longContextThreshold == 272_000)
    #expect(sol.longContextInputMultiplier == 2)
    #expect(sol.longContextOutputMultiplier == 1.5)
    #expect(sol.fastInputMultiplier == 2)
    #expect(sol.fastCachedInputMultiplier == 2)
    #expect(sol.fastCacheWriteMultiplier == 2)
    #expect(sol.fastOutputMultiplier == 2)
    #expect(sol.fastLongContextInputMultiplier == 4)
    #expect(sol.fastLongContextOutputMultiplier == 3)
    #expect(sol.creditsFastMultiplier == 2.5)
}

@Test func pricingParserRejectsPartialOfficialResponse() {
    let partial = chatGPTPricingFixture().replacingOccurrences(
        of: creditRow("GPT-5.6 Luna", "5", "0.5", "30"),
        with: ""
    )

    #expect(throws: OpenAIPricingCatalogError.self) {
        _ = try OpenAIPricingParser.parse(
            chatGPTMarkdown: partial,
            apiMarkdown: apiPricingFixture(),
            speedMarkdown: speedPricingFixture(),
            observedAt: .now
        )
    }
}

@Test func pricingParserRejectsMissingOfficialSpeedRates() {
    #expect(throws: OpenAIPricingCatalogError.self) {
        _ = try OpenAIPricingParser.parse(
            chatGPTMarkdown: chatGPTPricingFixture(),
            apiMarkdown: apiPricingFixture(),
            speedMarkdown: "# Speed\nRates unavailable.",
            observedAt: .now
        )
    }
}

@Test func pricingCalculatorSeparatesCacheWriteAndDoesNotDoubleCountReasoning() throws {
    let revision = try OpenAIPricingParser.parse(
        chatGPTMarkdown: chatGPTPricingFixture(),
        apiMarkdown: apiPricingFixture(),
        speedMarkdown: speedPricingFixture(),
        observedAt: .now
    )
    let usage = CodexTokenUsage(
        inputTokens: 200_000,
        cachedInputTokens: 40_000,
        cacheWriteInputTokens: 20_000,
        outputTokens: 10_000,
        reasoningOutputTokens: 9_000,
        totalTokens: 210_000
    )
    let totals = CodexUsageCostCalculator.totals(
        for: usage,
        modelID: "gpt-5.6-sol",
        speed: nil,
        revision: revision
    )

    // 140k uncached * $5 + 40k cached * $0.5 + 20k write * $6.25 + 10k output * $30.
    #expect(totals.apiEquivalentUSD == Decimal(string: "1.145"))
    // Reasoning is already part of the 10k output and is not billed a second time.
    #expect(totals.credits == Decimal(string: "28"))
}

@Test func pricingCalculatorAppliesLongContextAndFastModeToTheWholeRequest() throws {
    let revision = try OpenAIPricingParser.parse(
        chatGPTMarkdown: chatGPTPricingFixture(),
        apiMarkdown: apiPricingFixture(),
        speedMarkdown: speedPricingFixture(),
        observedAt: .now
    )
    let usage = CodexTokenUsage(inputTokens: 300_000, outputTokens: 10_000, totalTokens: 310_000)
    let standard = CodexUsageCostCalculator.totals(
        for: usage,
        modelID: "gpt-5.6-sol",
        speed: nil,
        revision: revision
    )
    let fast = CodexUsageCostCalculator.totals(
        for: usage,
        modelID: "gpt-5.6-sol",
        speed: "fast",
        revision: revision
    )

    #expect(standard.apiEquivalentUSD == Decimal(string: "3.45"))
    #expect(fast.apiEquivalentUSD == Decimal(string: "6.9"))
    #expect(fast.credits == standard.credits.map { $0 * Decimal(string: "2.5")! })
}

@Test func aggregatedShortRequestsDoNotBecomeLongContextPricing() throws {
    let revision = try OpenAIPricingParser.parse(
        chatGPTMarkdown: chatGPTPricingFixture(),
        apiMarkdown: apiPricingFixture(),
        speedMarkdown: speedPricingFixture(),
        observedAt: .now
    )
    let aggregated = CodexTokenUsage(inputTokens: 300_000, outputTokens: 10_000, totalTokens: 310_000)
    let shortRequests = CodexUsageCostCalculator.totals(
        for: aggregated,
        modelID: "gpt-5.6-sol",
        speed: nil,
        contextTier: .standard,
        revision: revision
    )
    let oneLongRequest = CodexUsageCostCalculator.totals(
        for: aggregated,
        modelID: "gpt-5.6-sol",
        speed: nil,
        contextTier: .long,
        revision: revision
    )

    #expect(shortRequests.apiEquivalentUSD == Decimal(string: "1.8"))
    #expect(oneLongRequest.apiEquivalentUSD == Decimal(string: "3.45"))
    #expect(shortRequests.credits == oneLongRequest.credits)
}

@Test func pricingCalculatorKeepsUnsupportedFastLongAPIPriceUnknown() throws {
    let revision = try OpenAIPricingParser.parse(
        chatGPTMarkdown: chatGPTPricingFixture(),
        apiMarkdown: apiPricingFixture(),
        speedMarkdown: speedPricingFixture(),
        observedAt: .now
    )
    let totals = CodexUsageCostCalculator.totals(
        for: CodexTokenUsage(inputTokens: 300_000, outputTokens: 1_000, totalTokens: 301_000),
        modelID: "gpt-5.5",
        speed: "fast",
        revision: revision
    )

    #expect(totals.credits != nil)
    #expect(totals.apiEquivalentUSD == nil)
}

@Test func unusedMissingCacheWriteRateDoesNotHideKnownAPIEquivalent() throws {
    let revision = try OpenAIPricingParser.parse(
        chatGPTMarkdown: chatGPTPricingFixture(),
        apiMarkdown: apiPricingFixture(),
        speedMarkdown: speedPricingFixture(),
        observedAt: .now
    )
    let totals = CodexUsageCostCalculator.totals(
        for: CodexTokenUsage(inputTokens: 100_000, outputTokens: 0, totalTokens: 100_000),
        modelID: "gpt-5.4",
        speed: nil,
        revision: revision
    )

    #expect(totals.apiEquivalentUSD == Decimal(string: "0.25"))
}

@Test func damagedPricingRefreshKeepsLastValidRevision() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-pricing-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let downloader = PricingFixtureDownloader(
        chatGPT: chatGPTPricingFixture(),
        api: apiPricingFixture(),
        speed: speedPricingFixture()
    )
    let catalog = OpenAIPricingCatalog(repository: repository, downloader: downloader)
    let valid = await catalog.refreshIfNeeded(now: Date(timeIntervalSince1970: 10_000), force: true)
    await downloader.setChatGPT("# incomplete")
    let damaged = await catalog.refreshIfNeeded(now: Date(timeIntervalSince1970: 20_000), force: true)

    #expect(valid.error == nil)
    #expect(damaged.error != nil)
    #expect(damaged.revision.id == valid.revision.id)
    #expect(try await repository.snapshot().rateCardRevisions.count == 1)
    await repository.close()
}

@Test func failedPricingDownloadIsPersistentlyThrottledForOneDay() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-pricing-throttle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let downloader = FailingPricingDownloader()
    let catalog = OpenAIPricingCatalog(repository: repository, downloader: downloader)
    let now = Date(timeIntervalSince1970: 10_000)

    let first = await catalog.refreshIfNeeded(now: now)
    let second = await catalog.refreshIfNeeded(now: now.addingTimeInterval(60))

    #expect(first.error != nil)
    #expect(second.fetched == false)
    #expect(second.error == nil)
    #expect(await downloader.requestCount == 3)
    let stored = try #require(try await repository.snapshot().rateCardRevisions.last)
    #expect(stored.observedAt == OpenAIPricingCatalog.bundledRevision.observedAt)
    #expect(stored.lastCheckedAt == now)
    await repository.close()
}

@Test func confirmedPriceChangeCarriesTheChangedRateKindAndValues() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-pricing-change-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let downloader = PricingFixtureDownloader(
        chatGPT: chatGPTPricingFixture(),
        api: apiPricingFixture(),
        speed: speedPricingFixture()
    )
    let catalog = OpenAIPricingCatalog(repository: repository, downloader: downloader)
    _ = await catalog.refreshIfNeeded(now: Date(timeIntervalSince1970: 10_000), force: true)
    await downloader.setChatGPT(
        chatGPTPricingFixture().replacingOccurrences(
            of: creditRow("GPT-5.6 Sol", "125", "12.5", "750"),
            with: creditRow("GPT-5.6 Sol", "250", "12.5", "750")
        )
    )

    let result = await catalog.refreshIfNeeded(now: Date(timeIntervalSince1970: 20_000), force: true)

    #expect(result.priceChange?.modelID == "gpt-5.6-sol")
    #expect(result.priceChange?.metric == .creditsInput)
    #expect(result.priceChange?.previousValue == 125)
    #expect(result.priceChange?.currentValue == 250)
    #expect(result.priceChange?.maximumPercentChange == 100)
    await repository.close()
}

@Test func confirmedFastCreditMultiplierChangeIsReported() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-pricing-speed-change-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let downloader = PricingFixtureDownloader(
        chatGPT: chatGPTPricingFixture(),
        api: apiPricingFixture(),
        speed: speedPricingFixture()
    )
    let catalog = OpenAIPricingCatalog(repository: repository, downloader: downloader)
    _ = await catalog.refreshIfNeeded(now: Date(timeIntervalSince1970: 10_000), force: true)
    await downloader.setSpeed(
        speedPricingFixture().replacingOccurrences(of: "2.5x", with: "3x")
    )

    let result = await catalog.refreshIfNeeded(now: Date(timeIntervalSince1970: 20_000), force: true)

    #expect(result.priceChange?.metric == .creditsFastMultiplier)
    #expect(result.priceChange?.previousValue == Decimal(string: "2.5"))
    #expect(result.priceChange?.currentValue == 3)
    #expect(result.priceChange?.maximumPercentChange == 20)
    await repository.close()
}

private actor PricingFixtureDownloader: OpenAIPricingDownloading {
    private var chatGPT: String
    private let api: String
    private var speed: String

    init(chatGPT: String, api: String, speed: String) {
        self.chatGPT = chatGPT
        self.api = api
        self.speed = speed
    }

    func setChatGPT(_ value: String) { chatGPT = value }
    func setSpeed(_ value: String) { speed = value }

    func download(_ url: URL) async throws -> OpenAIPricingDownload {
        let text: String
        if url.host == "developers.openai.com" {
            text = api
        } else if url.path.contains("agent-configuration/speed") {
            text = speed
        } else {
            text = chatGPT
        }
        return OpenAIPricingDownload(
            data: Data(text.utf8),
            statusCode: 200,
            mimeType: "text/markdown",
            finalURL: url
        )
    }
}

private actor FailingPricingDownloader: OpenAIPricingDownloading {
    private(set) var requestCount = 0

    func download(_ url: URL) async throws -> OpenAIPricingDownload {
        requestCount += 1
        throw URLError(.notConnectedToInternet)
    }
}

private func speedPricingFixture() -> String {
    """
    # Speed
    Fast mode currently supports GPT-5.6, GPT-5.5, and GPT-5.4.
    GPT-5.6 and GPT-5.5 consume credits at 2.5x the Standard rate;
    GPT-5.4 consumes credits at 2x the Standard rate.
    """
}

private func chatGPTPricingFixture() -> String {
    """
    # Pricing
    <table>
      <thead><tr><th>Credits per 1M tokens</th><th>Input Tokens</th><th>Cached input tokens</th><th>Output Tokens</th></tr></thead>
      <tbody>
        \(creditRow("GPT-5.6 Sol", "125", "12.5", "750"))
        \(creditRow("GPT-5.6 Terra", "50", "5", "300"))
        \(creditRow("GPT-5.6 Luna", "5", "0.5", "30"))
        \(creditRow("GPT-5.5", "125", "12.5", "750"))
        \(creditRow("GPT-5.4", "62.5", "6.25", "375"))
        \(creditRow("GPT-5.4 mini", "18.75", "1.875", "113"))
      </tbody>
    </table>
    """
}

private func creditRow(_ model: String, _ input: String, _ cached: String, _ output: String) -> String {
    "<tr><td>\(model)</td><td>\(input) credits</td><td>\(cached) credits</td><td>\(output) credits</td></tr>"
}

private func apiPricingFixture() -> String {
    """
    # Pricing
    ### Standard pricing data
    | Model | Short context input | Short context cached input | Short context cache writes | Short context output | Long context input | Long context cached input | Long context cache writes | Long context output |
    | --- | --- | --- | --- | --- | --- | --- | --- | --- |
    | gpt-5.6-sol | $5.00 | $0.50 | $6.25 | $30.00 | $10.00 | $1.00 | $12.50 | $45.00 |
    | gpt-5.6-terra | $2.00 | $0.20 | $2.50 | $12.00 | $4.00 | $0.40 | $5.00 | $18.00 |
    | gpt-5.6-luna | $0.20 | $0.02 | $0.25 | $1.20 | $0.40 | $0.04 | $0.50 | $1.80 |
    | gpt-5.5 (<272K context length) | $5.00 | $0.50 | - | $30.00 | $10.00 | $1.00 | - | $45.00 |
    | gpt-5.4 (<272K context length) | $2.50 | $0.25 | - | $15.00 | $5.00 | $0.50 | - | $22.50 |
    | gpt-5.4-mini | $0.75 | $0.075 | - | $4.50 | - | - | - | - |

    ### Fast pricing data
    | Model | Short context input | Short context cached input | Short context cache writes | Short context output | Long context input | Long context cached input | Long context cache writes | Long context output |
    | --- | --- | --- | --- | --- | --- | --- | --- | --- |
    | gpt-5.6-sol | $10.00 | $1.00 | $12.50 | $60.00 | $20.00 | $2.00 | $25.00 | $90.00 |
    | gpt-5.6-terra | $4.00 | $0.40 | $5.00 | $24.00 | $8.00 | $0.80 | $10.00 | $36.00 |
    | gpt-5.6-luna | $0.40 | $0.04 | $0.50 | $2.40 | $0.80 | $0.08 | $1.00 | $3.60 |
    | gpt-5.5 (<272K context length) | $12.50 | $1.25 | - | $75.00 | - | - | - | - |
    | gpt-5.4 (<272K context length) | $5.00 | $0.50 | - | $30.00 | - | - | - | - |
    | gpt-5.4-mini | $1.50 | $0.15 | - | $9.00 | - | - | - | - |
    """
}

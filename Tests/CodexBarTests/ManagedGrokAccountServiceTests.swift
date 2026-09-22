import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct ManagedGrokAccountServiceTests {
    @Test
    func `add account stores email and home under the managed root`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryManagedGrokAccountStore(
            snapshot: ManagedGrokAccountSet(version: 1, accounts: []))
        let service = ManagedGrokAccountService(
            store: store,
            homeFactory: TestManagedGrokHomeFactory(root: root),
            loginRunner: StubManagedGrokLoginRunner.success,
            identityReader: StubManagedGrokIdentityReader(email: "grok-a@example.com", userID: "user-a"))

        let account = try await service.authenticateManagedAccount()
        #expect(account.email == "grok-a@example.com")
        #expect(account.userID == "user-a")
        #expect(account.managedHomePath.hasPrefix(root.standardizedFileURL.path + "/"))
        #expect(store.snapshot.accounts.count == 1)
    }

    @Test
    func `same email upserts instead of duplicating`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryManagedGrokAccountStore(
            snapshot: ManagedGrokAccountSet(version: 1, accounts: []))
        let service = ManagedGrokAccountService(
            store: store,
            homeFactory: TestManagedGrokHomeFactory(root: root),
            loginRunner: StubManagedGrokLoginRunner.success,
            identityReader: StubManagedGrokIdentityReader(email: "grok-a@example.com", userID: "user-a"))

        let first = try await service.authenticateManagedAccount()
        let second = try await service.authenticateManagedAccount()
        #expect(first.id == second.id)
        #expect(store.snapshot.accounts.count == 1)
    }

    @Test
    func `missing email fails closed and deletes the new home`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryManagedGrokAccountStore(
            snapshot: ManagedGrokAccountSet(version: 1, accounts: []))
        let service = ManagedGrokAccountService(
            store: store,
            homeFactory: TestManagedGrokHomeFactory(root: root),
            loginRunner: StubManagedGrokLoginRunner.success,
            identityReader: StubManagedGrokIdentityReader(email: nil, userID: "user-a"))

        await #expect(throws: ManagedGrokAccountServiceError.missingEmail) {
            _ = try await service.authenticateManagedAccount()
        }
        #expect(store.snapshot.accounts.isEmpty)
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(leftover.isEmpty)
    }
}

struct GrokVisibleAccountProjectionTests {
    @Test
    func `live plus managed accounts expose stacked identities`() {
        let managedID = UUID()
        let projection = GrokVisibleAccountProjectionFactory.make(
            liveEmail: "system@example.com",
            liveHomePath: "/tmp/live-grok",
            managedAccounts: [
                ManagedGrokAccount(
                    id: managedID,
                    email: "second@example.com",
                    managedHomePath: "/tmp/managed-grok",
                    createdAt: 1,
                    updatedAt: 1,
                    lastAuthenticatedAt: 1),
            ],
            persistedSource: .managedAccount(id: managedID),
            hasUnreadableAddedAccountStore: false)

        #expect(projection.visibleAccounts.count == 2)
        #expect(projection.liveVisibleAccountID == GrokVisibleAccount.liveAccountID)
        #expect(projection.activeVisibleAccountID == managedID.uuidString)
        #expect(projection.visibleAccounts[0].isLive)
        #expect(projection.visibleAccounts[1].canRemove)
    }

    @Test
    func `missing managed selection falls back to live`() {
        let projection = GrokVisibleAccountProjectionFactory.make(
            liveEmail: "system@example.com",
            liveHomePath: "/tmp/live-grok",
            managedAccounts: [],
            persistedSource: .managedAccount(id: UUID()),
            hasUnreadableAddedAccountStore: false)
        #expect(projection.activeVisibleAccountID == GrokVisibleAccount.liveAccountID)
        #expect(GrokActiveSourceResolver.resolve(
            persistedSource: .managedAccount(id: UUID()),
            liveAccount: projection.visibleAccounts.first,
            managedAccounts: []) == .liveSystem)
    }

    @Test
    @MainActor
    func `unreadable managed store keeps the saved selection`() throws {
        let settings = testSettingsStore(suiteName: "GrokUnreadableStore")
        let accountID = UUID()
        settings.grokActiveSource = .managedAccount(id: accountID)
        let store = FileManagedGrokAccountStore()
        let previous = try? store.loadAccounts()
        defer { if let previous { try? store.storeAccounts(previous) } }
        try Data("not-json".utf8).write(to: FileManagedGrokAccountStore.defaultURL())
        #expect(settings.grokManagedAccountStoreIsUnreadable)
        #expect(settings.grokResolvedActiveSource == .managedAccount(id: accountID))
        #expect(settings.persistResolvedGrokActiveSourceCorrectionIfNeeded() == false)
        #expect(settings.grokUsesHomeAccounts)
        let implementation = GrokProviderImplementation()
        let context = ProviderSettingsContext(
            provider: .grok,
            settings: settings,
            store: UsageStore(
                fetcher: UsageFetcher(environment: [:]),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings,
                startupBehavior: .testing),
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in },
            runLoginFlow: {})
        let picker = try #require(implementation.settingsPickers(context: context)
            .first { $0.id == "grok-usage-source" })
        #expect(picker.isEnabled?() == false)
        #expect(try implementation.tokenAccountsVisibility(
            context: context,
            support: #require(TokenAccountSupportCatalog.support(for: .grok))) == false)
    }
}

struct GrokHomeScopeTests {
    @Test
    func `scoped environment sets GROK_HOME and strips pasted oauth tokens`() {
        let env = GrokHomeScope.scopedEnvironment(
            base: [
                "PATH": "/usr/bin",
                GrokSettingsReader.oauthTokenEnvironmentKey: "pasted-token",
            ],
            grokHome: "/tmp/grok-b")
        #expect(env["GROK_HOME"] == "/tmp/grok-b")
        #expect(env[GrokSettingsReader.oauthTokenEnvironmentKey] == nil)
        #expect(env["PATH"] == "/usr/bin")
    }
}

private struct TestManagedGrokHomeFactory: ManagedGrokHomeProducing {
    let root: URL

    func makeHomeURL() -> URL {
        self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        let rootPath = self.root.standardizedFileURL.path + "/"
        let targetPath = url.standardizedFileURL.path
        guard targetPath.hasPrefix(rootPath) else {
            throw ManagedGrokAccountServiceError.unsafeManagedHome(url.path)
        }
    }
}

private struct StubManagedGrokLoginRunner: ManagedGrokLoginRunning {
    static let success = StubManagedGrokLoginRunner()

    func run(
        homePath _: String,
        timeout _: TimeInterval,
        onProgress _: (@Sendable (String) -> Void)?) async -> CLILoginRunner.Result
    {
        CLILoginRunner.Result(outcome: .success, output: "ok")
    }
}

private struct StubManagedGrokIdentityReader: ManagedGrokIdentityReading {
    let email: String?
    let userID: String?

    func loadAccountIdentity(homePath _: String) throws -> GrokCredentials {
        GrokCredentials(
            accessToken: "token",
            refreshToken: "refresh",
            scope: "https://auth.x.ai::test",
            authMode: "oidc",
            userId: self.userID,
            email: self.email,
            firstName: nil,
            lastName: nil,
            teamId: nil,
            oidcIssuer: nil,
            oidcClientId: nil,
            expiresAt: nil,
            createTime: nil)
    }
}

private final class InMemoryManagedGrokAccountStore: ManagedGrokAccountStoring, @unchecked Sendable {
    var snapshot: ManagedGrokAccountSet

    init(snapshot: ManagedGrokAccountSet) {
        self.snapshot = snapshot
    }

    func loadAccounts() throws -> ManagedGrokAccountSet {
        self.snapshot
    }

    func storeAccounts(_ accounts: ManagedGrokAccountSet) throws {
        self.snapshot = accounts
    }
}

struct GrokAccountMenuDisplayTests {
    @Test
    func `single home account hides token controls without showing a redundant switcher`() {
        let display = GrokAccountMenuDisplay(
            accounts: [Self.account("one@example.com")],
            snapshots: [],
            activeVisibleAccountID: "one@example.com",
            layout: .segmented)
        #expect(!display.showSwitcher)
        #expect(GrokAccountMenuSupport.suppressesTokenAccounts(provider: .grok, usesHomeAccounts: true))
        #expect(!GrokAccountMenuSupport.suppressesTokenAccounts(provider: .grok, usesHomeAccounts: false))
        #expect(!GrokAccountMenuSupport.suppressesTokenAccounts(provider: .codex, usesHomeAccounts: true))
    }

    @Test(arguments: ["live", "managed-account"])
    func `cache ownership rejects reassigned identity or home with unchanged ID`(accountID: String) {
        func account(email: String, home: String) -> GrokVisibleAccount {
            GrokVisibleAccount(
                id: accountID,
                email: email,
                storedAccountID: nil,
                selectionSource: .liveSystem,
                managedHomePath: home,
                isActive: true,
                isLive: true,
                canReauthenticate: true,
                canRemove: false)
        }
        let original = account(email: "old@example.com", home: "/tmp/grok-original")
        let cached = GrokAccountUsageSnapshot(account: original, snapshot: nil, error: nil, sourceLabel: nil)
        #expect(cached.matches(original))
        #expect(!cached.matches(account(email: "new@example.com", home: "/tmp/grok-original")))
        #expect(!cached.matches(account(email: "old@example.com", home: "/tmp/grok-replaced")))
    }

    @Test
    func `segmented layout shows a switcher instead of stacked cards`() {
        let display = GrokAccountMenuDisplay(
            accounts: [Self.account("one@example.com"), Self.account("two@example.com")],
            snapshots: [],
            activeVisibleAccountID: "one@example.com",
            layout: .segmented)
        #expect(display.showSwitcher)
        #expect(display.showAll == false)
    }

    @Test
    func `stacked layout shows all cards`() {
        let display = GrokAccountMenuDisplay(
            accounts: [Self.account("one@example.com"), Self.account("two@example.com")],
            snapshots: [],
            activeVisibleAccountID: "one@example.com",
            layout: .stacked)
        #expect(display.showAll)
        #expect(display.showSwitcher == false)
    }

    private static func account(_ email: String) -> GrokVisibleAccount {
        GrokVisibleAccount(
            id: email,
            email: email,
            storedAccountID: nil,
            selectionSource: .liveSystem,
            managedHomePath: nil,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
    }
}

@Suite(.serialized)
struct GrokManagedAccountRoutingTests {
    @Test
    @MainActor
    func `live routing preserves ambient GROK_HOME and oauth token`() {
        let settings = testSettingsStore(suiteName: "GrokRouting-live")
        let env = ProviderRegistry.makeEnvironment(
            base: [
                "GROK_HOME": "/tmp/ambient-grok",
                GrokSettingsReader.oauthTokenEnvironmentKey: "ambient-token",
            ],
            provider: .grok,
            settings: settings,
            tokenOverride: nil)
        #expect(env["GROK_HOME"] == "/tmp/ambient-grok")
        #expect(env[GrokSettingsReader.oauthTokenEnvironmentKey] == "ambient-token")
    }

    @Test
    @MainActor
    func `managed routing scopes home and strips ambient oauth token`() async throws {
        let settings = testSettingsStore(suiteName: "GrokRouting-managed")
        let accountID = UUID()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "grok-managed-\(accountID.uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = FileManagedGrokAccountStore()
        let previous = (try? store.loadAccounts()) ?? ManagedGrokAccountSet(version: 1, accounts: [])
        defer { try? store.storeAccounts(previous) }
        try store.storeAccounts(
            ManagedGrokAccountSet(
                version: 1,
                accounts: [
                    ManagedGrokAccount(
                        id: accountID,
                        email: "managed@example.com",
                        managedHomePath: home.path,
                        createdAt: 1,
                        updatedAt: 1,
                        lastAuthenticatedAt: 1),
                ]))
        settings.grokActiveSource = .managedAccount(id: accountID)

        let env = ProviderRegistry.makeEnvironment(
            base: [
                "GROK_HOME": "/tmp/ambient-grok",
                GrokSettingsReader.oauthTokenEnvironmentKey: "ambient-token",
            ],
            provider: .grok,
            settings: settings,
            tokenOverride: nil)
        #expect(env["GROK_HOME"] == GrokHomeScope.normalizedHomePath(home.path))
        #expect(env[GrokSettingsReader.oauthTokenEnvironmentKey] == nil)

        settings.addTokenAccount(provider: .grok, label: "Pasted A", token: "fake-token-a")
        settings.addTokenAccount(provider: .grok, label: "Pasted B", token: "fake-token-b")
        let usageStore = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let baseSpec = try #require(usageStore.providerSpecs[.grok])
        let baseDescriptor = baseSpec.descriptor
        usageStore.providerSpecs[.grok] = ProviderSpec(
            style: baseSpec.style,
            isEnabled: { true },
            descriptor: ProviderDescriptor(
                id: .grok,
                metadata: baseDescriptor.metadata,
                branding: baseDescriptor.branding,
                tokenCost: baseDescriptor.tokenCost,
                fetchPlan: ProviderFetchPlan(
                    sourceModes: [.oauth],
                    pipeline: ProviderFetchPipeline { _ in [GrokManagedOwnershipTestStrategy()] }),
                cli: baseDescriptor.cli),
            makeFetchContext: baseSpec.makeFetchContext)
        for layout in [MultiAccountMenuLayout.segmented, .stacked] {
            settings.multiAccountMenuLayout = layout
            #expect(usageStore.shouldFetchAllGrokVisibleAccounts())
            await usageStore.refreshProvider(.grok, allowDisabled: true)
            #expect(usageStore.snapshot(for: .grok)?.accountEmail(for: .grok) == "managed@example.com")
            #expect(usageStore.accountSnapshots[.grok]?.isEmpty != false)
        }
        let managedContext = usageStore.makeFetchContext(provider: .grok, override: nil)
        #expect(managedContext.sourceMode == .oauth)
        #expect(managedContext.selectedTokenAccountID == nil)
        #expect(managedContext.grokExpectedAccountEmail == "managed@example.com")

        let pastedAccount = ProviderTokenAccount(
            id: UUID(), label: "Pasted", token: "fake-pasted-token", addedAt: 1, lastUsed: nil)
        let pastedContext = usageStore.makeFetchContext(
            provider: .grok,
            override: TokenAccountOverride(provider: .grok, account: pastedAccount))
        #expect(pastedContext.selectedTokenAccountID == pastedAccount.id)
        #expect(pastedContext.grokExpectedAccountEmail == nil)
        #expect(pastedContext.env["GROK_HOME"] != home.path)
        #expect(pastedContext.env[GrokSettingsReader.oauthTokenEnvironmentKey] == pastedAccount.token)

        let priorSnapshots = usageStore.grokAccountSnapshots
        try store.storeAccounts(ManagedGrokAccountSet(version: 1, accounts: [
            ManagedGrokAccount(
                id: accountID,
                email: "reassigned@example.com",
                managedHomePath: home.path,
                createdAt: 1,
                updatedAt: 2,
                lastAuthenticatedAt: 2),
        ]))
        let activeID = try #require(settings.grokVisibleAccountProjection.activeVisibleAccountID)
        usageStore.activateCachedGrokAccountSnapshot(visibleAccountID: activeID)
        #expect(usageStore.snapshot(for: .grok) == nil)
        #expect(usageStore.lastKnownResetSnapshots[.grok] == nil)
        usageStore.grokAccountSnapshots = priorSnapshots
        await usageStore.refreshProvider(.grok, allowDisabled: true)
        #expect(usageStore.snapshot(for: .grok) == nil)
        let reassigned = try #require(usageStore.grokAccountSnapshots.first { $0.id == activeID })
        #expect(reassigned.snapshot == nil)
        #expect(reassigned.error != nil)
    }

    @Test
    @MainActor
    func `removed managed override cannot fall back to ambient credentials`() {
        let settings = testSettingsStore(suiteName: "GrokRouting-removed")
        let env = ProviderRegistry.makeEnvironment(
            base: ["GROK_HOME": "/tmp/ambient-grok", GrokSettingsReader.oauthTokenEnvironmentKey: "fake-token"],
            provider: .grok,
            settings: settings,
            tokenOverride: nil,
            grokActiveSourceOverride: .managedAccount(id: UUID()))
        #expect(env["GROK_HOME"] == "/dev/null")
        #expect(env[GrokSettingsReader.oauthTokenEnvironmentKey] == nil)
    }

    @Test
    @MainActor
    func `explicit System override binds the System home and removes competing credentials`() {
        let settings = testSettingsStore(suiteName: "GrokRouting-live-override")
        settings.grokActiveSource = .managedAccount(id: UUID())
        let env = ProviderRegistry.makeEnvironment(
            base: [
                "GROK_HOME": "/tmp/ambient-grok",
                GrokSettingsReader.oauthTokenEnvironmentKey: "ambient-token",
            ],
            provider: .grok,
            settings: settings,
            tokenOverride: nil,
            grokActiveSourceOverride: .liveSystem)
        #expect(env["GROK_HOME"] == settings.grokHomePath(forActiveSource: .liveSystem))
        #expect(env[GrokSettingsReader.oauthTokenEnvironmentKey] == nil)
    }

    @Test
    func `fetched identity is compared before any relabel`() {
        #expect(GrokFetchedAccountIdentity.matches("Managed@Example.com", storedEmail: "managed@example.com"))
        #expect(GrokFetchedAccountIdentity.matches("other@example.com", storedEmail: "managed@example.com") == false)
        #expect(!GrokFetchedAccountIdentity.matches(nil, storedEmail: "managed@example.com"))
        #expect(!GrokFetchedAccountIdentity.matches("  ", storedEmail: "managed@example.com"))
    }
}

private struct GrokManagedOwnershipTestStrategy: ProviderFetchStrategy {
    let id = "grok-test-owner"
    let kind: ProviderFetchKind = .oauth

    func isAvailable(_: ProviderFetchContext) async -> Bool { true }

    func shouldFallback(on _: any Error, context _: ProviderFetchContext) -> Bool { false }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        #expect(context.selectedTokenAccountID == nil)
        #expect(context.env[GrokSettingsReader.oauthTokenEnvironmentKey] == nil)
        let email = try #require(context.grokExpectedAccountEmail)
        #expect(!email.isEmpty)
        if email == "reassigned@example.com" {
            throw GrokWebBillingError.invalidResponse
        }
        return ProviderFetchResult(
            usage: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()).withIdentity(
                ProviderIdentitySnapshot(
                    providerID: UsageProvider.grok.instanceID,
                    accountEmail: email,
                    accountOrganization: nil,
                    loginMethod: nil)),
            credits: nil,
            dashboard: nil,
            sourceLabel: "oauth",
            strategyID: self.id,
            strategyKind: self.kind)
    }
}

@Test
@MainActor
func `managed history does not use the selected pasted account`() async throws {
    let settings = testSettingsStore(suiteName: "GrokHistoryOwner")
    settings.historicalTrackingEnabled = true
    settings.addTokenAccount(provider: .grok, label: "Pasted", token: "fake-token")
    let pasted = try #require(settings.tokenAccounts(for: .grok).first)
    let managedID = UUID()
    let account = GrokVisibleAccount(
        id: managedID.uuidString,
        email: "managed@example.com",
        storedAccountID: managedID,
        selectionSource: .managedAccount(id: managedID),
        managedHomePath: "/tmp/managed-grok",
        isActive: true,
        isLive: false,
        canReauthenticate: true,
        canRemove: true)
    let store = UsageStore(
        fetcher: UsageFetcher(environment: [:]),
        browserDetection: BrowserDetection(cacheTTL: 0),
        settings: settings,
        startupBehavior: .testing,
        environmentBase: [:])
    let snapshot = UsageSnapshot(
        primary: RateWindow(
            usedPercent: 22,
            windowMinutes: 7 * 24 * 60,
            resetsAt: Date().addingTimeInterval(86400),
            resetDescription: nil),
        secondary: nil,
        updatedAt: Date())
    await store.recordPlanUtilizationHistorySample(
        provider: .grok,
        snapshot: snapshot,
        account: store.grokPlanHistoryAccount(for: account))
    let managedBuckets = try #require(store.planUtilizationHistory[.grok])
    let pastedOnly = UsageStore(
        fetcher: UsageFetcher(environment: [:]),
        browserDetection: BrowserDetection(cacheTTL: 0),
        settings: settings,
        startupBehavior: .testing,
        environmentBase: [:])
    await pastedOnly.recordPlanUtilizationHistorySample(provider: .grok, snapshot: snapshot)
    let pastedBuckets = try #require(pastedOnly.planUtilizationHistory[.grok])
    #expect(managedBuckets.preferredAccountKey != nil)
    #expect(managedBuckets.preferredAccountKey != pastedBuckets.preferredAccountKey)
    _ = pasted
}

struct GrokAccountSwitcherPrivacyTests {
    @Test
    @MainActor
    func `hide personal info does not put email in tooltips`() {
        let accounts = [
            GrokAccountMenuDisplayTestsAccount.make("alpha@example.com"),
            GrokAccountMenuDisplayTestsAccount.make("beta@example.com"),
        ]
        let view = GrokAccountSwitcherView(
            accounts: accounts,
            selectedAccountID: accounts[0].id,
            width: 320,
            hidePersonalInfo: true,
            onSelect: { _ in })
        let tooltips = view._test_buttonToolTips()
        #expect(!tooltips.isEmpty)
        #expect(!tooltips.contains { $0.contains("@") })
    }
}

private enum GrokAccountMenuDisplayTestsAccount {
    static func make(_ email: String) -> GrokVisibleAccount {
        GrokVisibleAccount(
            id: email,
            email: email,
            storedAccountID: nil,
            selectionSource: .liveSystem,
            managedHomePath: nil,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
    }
}

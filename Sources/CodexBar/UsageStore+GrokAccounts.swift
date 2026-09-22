import CodexBarCore
import Foundation

extension UsageStore {
    func grokFetchSource(
        _ provider: UsageProvider,
        tokenOverride: TokenAccountOverride?,
        sourceOverride: GrokActiveSource?) -> GrokActiveSource?
    {
        guard provider == .grok else { return nil }
        if let sourceOverride { return sourceOverride }
        guard tokenOverride == nil else { return nil }
        let source = self.settings.grokResolvedActiveSource
        return source.usesManagedHome ? source : nil
    }

    func grokExpectedAccountEmail(for source: GrokActiveSource?) -> String? {
        source.map { source in
            self.settings.grokVisibleAccountProjection.visibleAccounts
                .first { $0.selectionSource == source }?.email ?? ""
        }
    }

    func shouldFetchAllGrokVisibleAccounts() -> Bool {
        self.settings.grokUsesHomeAccounts
    }

    func activateCachedGrokAccountSnapshot(visibleAccountID: String) {
        let projection = self.settings.grokVisibleAccountProjection
        guard projection.activeVisibleAccountID == visibleAccountID else { return }
        guard let account = projection.account(id: visibleAccountID),
              let cached = self.grokAccountSnapshots.first(where: { $0.matches(account) })
        else {
            self.snapshots[.grok] = nil
            self.lastKnownResetSnapshots[.grok] = nil
            self.errors[.grok] = nil
            self.lastSourceLabels[.grok] = nil
            return
        }
        self.snapshots[.grok] = cached.snapshot
        self.errors[.grok] = cached.error
        self.lastKnownResetSnapshots[.grok] = cached.snapshot
        self.lastSourceLabels[.grok] = cached.sourceLabel
    }

    func refreshGrokVisibleAccountsForMenu(generation: UInt64? = nil) async {
        let projection = self.settings.grokVisibleAccountProjection
        let accounts = self.settings.multiAccountMenuLayout == .stacked
            ? projection.visibleAccounts
            : projection.visibleAccounts.filter { $0.id == projection.activeVisibleAccountID }
        guard !accounts.isEmpty else {
            self.grokAccountSnapshots = []
            return
        }

        let originalVisibleAccountID = projection.activeVisibleAccountID
        if let originalVisibleAccountID {
            self.activateCachedGrokAccountSnapshot(visibleAccountID: originalVisibleAccountID)
        }
        let priorSnapshots = self.grokAccountSnapshots
        var snapshots: [GrokAccountUsageSnapshot] = []
        var selectedOutcome: ProviderFetchOutcome?
        var selectedSnapshot: UsageSnapshot?

        let results = await self.fetchGrokVisibleAccountOutcomes(accounts)
        guard !Task.isCancelled,
              self.isCurrentProviderRefreshGeneration(.grok, generation: generation)
        else { return }

        let currentProjection = self.settings.grokVisibleAccountProjection
        for result in results {
            guard let account = currentProjection.account(id: result.account.id),
                  account.email == result.account.email,
                  account.managedHomePath == result.account.managedHomePath
            else { continue }
            let prior = priorSnapshots.first { $0.matches(account) }
            switch result.outcome.result {
            case let .success(fetchResult):
                let fetched = fetchResult.usage.scoped(to: .grok)
                guard GrokFetchedAccountIdentity.matches(
                    fetched.accountEmail(for: .grok),
                    storedEmail: account.email)
                else {
                    snapshots.append(GrokAccountUsageSnapshot(
                        account: account,
                        snapshot: prior?.snapshot,
                        error: L("Grok account identity did not match the selected home."),
                        sourceLabel: prior?.sourceLabel))
                    continue
                }
                let usage = self.relabeledGrokUsage(fetched, account: account)
                snapshots.append(GrokAccountUsageSnapshot(
                    account: account,
                    snapshot: usage,
                    error: nil,
                    sourceLabel: fetchResult.sourceLabel))
                if account.id == originalVisibleAccountID {
                    selectedOutcome = result.outcome
                    selectedSnapshot = usage
                }
            case let .failure(error):
                snapshots.append(GrokAccountUsageSnapshot(
                    account: account,
                    snapshot: prior?.snapshot,
                    error: error.localizedDescription,
                    sourceLabel: prior?.sourceLabel))
                if account.id == originalVisibleAccountID {
                    selectedOutcome = result.outcome
                    selectedSnapshot = prior?.snapshot
                }
            }
        }

        self.grokAccountSnapshots = snapshots
        if let activeID = currentProjection.activeVisibleAccountID {
            self.activateCachedGrokAccountSnapshot(visibleAccountID: activeID)
        }
        if currentProjection.activeVisibleAccountID == originalVisibleAccountID, let selectedOutcome {
            await self.applySelectedOutcome(
                selectedOutcome,
                provider: .grok,
                account: nil,
                fallbackSnapshot: selectedSnapshot,
                generation: generation)
            if let selectedSnapshot {
                self.snapshots[.grok] = selectedSnapshot
            }
        }
    }

    private func fetchGrokVisibleAccountOutcomes(_ accounts: [GrokVisibleAccount]) async
        -> [(account: GrokVisibleAccount, outcome: ProviderFetchOutcome)]
    {
        var results: [(account: GrokVisibleAccount, outcome: ProviderFetchOutcome)] = []
        for account in accounts {
            let context = self.makeFetchContext(
                provider: .grok,
                override: nil,
                grokActiveSourceOverride: account.selectionSource)
            guard context.grokExpectedAccountEmail == account.email,
                  context.env["GROK_HOME"] == account.managedHomePath
            else {
                results.append((account: account, outcome: ProviderFetchOutcome(
                    result: .failure(GrokWebBillingError.missingCredentials), attempts: [])))
                continue
            }
            let descriptor = self.providerSpecs[.grok]?.descriptor
                ?? ProviderDescriptorRegistry.descriptor(for: .grok)
            let outcome = await descriptor.fetchOutcome(context: context)
            results.append((account: account, outcome: outcome))
        }
        return results
    }

    private func relabeledGrokUsage(_ usage: UsageSnapshot, account: GrokVisibleAccount) -> UsageSnapshot {
        let scoped = usage.scoped(to: .grok)
        return scoped.withIdentity(ProviderIdentitySnapshot(
            providerID: UsageProvider.grok.instanceID,
            accountEmail: account.email,
            accountOrganization: scoped.accountOrganization(for: .grok),
            loginMethod: scoped.loginMethod(for: .grok)))
    }
}

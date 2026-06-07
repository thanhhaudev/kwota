//
//  AntigravityUsageSnapshot.swift
//  Kwota
//
//  Decoded shape of GetUserStatus from the Antigravity language_server's
//  local Connect-RPC endpoint. Antigravity uses a credit-based quota model
//  with separate Prompt and Flow credit pools, plus per-model rate-limit
//  quotaInfo. Proto3-aware: missing remainingFraction inside an existing
//  quotaInfo object means 0%, while an absent quotaInfo means no-limit.
//

import Foundation

struct AntigravityUsageSnapshot: Decodable, Equatable, Sendable {
    var fetchedAt: Date
    /// "Enable AI Credit Overages" toggle from Antigravity's
    /// state.vscdb, attached post-decode by `AntigravityProvider`.
    /// nil = read failed or never attempted (treat as unknown).
    var overagesEnabled: Bool?
    /// AI-credit balance read from state.vscdb's modelCredits blob,
    /// attached post-decode by `AntigravityProvider`. Used as a FALLBACK
    /// for `aiCreditsWallet` when the live API returns no wallet entry —
    /// the API (`userTier.availableCredits`) stays source of truth when
    /// populated. nil = not read / not needed.
    var aiCreditsFallback: Int64?
    let name: String?
    let email: String?
    let planInfo: PlanInfo?
    let availablePromptCredits: Int64?
    let availableFlowCredits: Int64?
    let models: [ModelQuota]?
    /// Cross-product Google AI Pro / Ultra credit wallet entries, decoded
    /// from `userTier.availableCredits`. The balance in each entry is
    /// shared across Antigravity, Google Flow (video gen), and other
    /// Google AI surfaces — Kwota only surfaces the number, never the
    /// cause of consumption.
    ///
    /// Modeled as an array because the proto field is repeated and entries
    /// carry a `creditType` discriminator (`"GOOGLE_ONE_AI"` observed; the
    /// shape is set up for future Ultra/top-up entries). Today the live
    /// endpoint returns exactly one entry — see `aiCreditsWallet` for the
    /// view convenience that reads the first balance.
    let availableCredits: [WalletEntry]
    /// Authoritative plan-tier name from `userTier.name`, e.g.
    /// `"Google AI Pro"` or `"Google AI Ultra"`. More accurate than
    /// `planInfo.planName` (which may abbreviate to "Pro"). Used by
    /// `AntigravityTier.detect` to classify the account.
    let userTierName: String?
    let schemaVersion: Int

    /// One credit wallet entry from `userTier.availableCredits[]`.
    struct WalletEntry: Decodable, Equatable, Sendable {
        /// Discriminator, e.g. `"GOOGLE_ONE_AI"`. Future values may
        /// include top-up bundles or Ultra-tier credits.
        let creditType: String?
        /// Available balance for this wallet. Wire-encodes as string in
        /// proto3 JSON; `flexibleInt64` accepts both.
        let creditAmount: Int64?
        /// Minimum balance required for the wallet to be spendable. When
        /// `creditAmount < minimumCreditAmountForUsage` the credits are
        /// stranded (cannot be drawn). Observed value: 50.
        let minimumCreditAmountForUsage: Int64?

        enum CodingKeys: String, CodingKey {
            case creditType, creditAmount, minimumCreditAmountForUsage
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.creditType = try c.decodeIfPresent(String.self, forKey: .creditType)
            // Proto3 zero-elision: when the WalletEntry is present but
            // `creditAmount` is omitted, the balance is 0 (not unknown). A
            // nil here would let `aiCreditsWallet` fall back to the stale
            // state.vscdb sentinel, lying that the wallet is full when it's
            // actually drained. Mirrors `ModelQuota.remainingFraction`'s
            // `?? 0` for the same proto3 reason.
            self.creditAmount = (try Self.flexibleInt64(c, .creditAmount)) ?? 0
            self.minimumCreditAmountForUsage = try Self.flexibleInt64(c, .minimumCreditAmountForUsage)
        }
        init(creditType: String?, creditAmount: Int64?, minimumCreditAmountForUsage: Int64? = nil) {
            self.creditType = creditType
            self.creditAmount = creditAmount
            self.minimumCreditAmountForUsage = minimumCreditAmountForUsage
        }
        private static func flexibleInt64(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) throws -> Int64? {
            if let n = try? c.decodeIfPresent(Int64.self, forKey: k) { return n }
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Int64(s) }
            return nil
        }
    }

    struct PlanInfo: Codable, Equatable, Sendable {
        let planName: String?
        let teamsTier: String?
        /// Wire name is `monthlyPromptCredits` (kept verbatim to match the
        /// proto JSON field), but the observed behavior is a **rate-limit
        /// window ceiling**, not a strict monthly pool. When the balance
        /// hits 0, Antigravity downgrades the user to a smaller model
        /// rather than blocking. Reset cadence is server-side and is not
        /// exposed on this endpoint — see `availablePromptCredits` for the
        /// remaining headroom in the current window.
        let monthlyPromptCredits: Int64?
        /// Same caveat as `monthlyPromptCredits`. Flow credits are agentic
        /// tool-use steps and burn far faster than prompt credits during
        /// long-horizon agent loops.
        let monthlyFlowCredits: Int64?

        enum CodingKeys: String, CodingKey {
            case planName, teamsTier, monthlyPromptCredits, monthlyFlowCredits
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.planName = try c.decodeIfPresent(String.self, forKey: .planName)
            self.teamsTier = try c.decodeIfPresent(String.self, forKey: .teamsTier)
            self.monthlyPromptCredits = try Self.flexibleInt64(c, .monthlyPromptCredits)
            self.monthlyFlowCredits = try Self.flexibleInt64(c, .monthlyFlowCredits)
        }
        private static func flexibleInt64(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) throws -> Int64? {
            if let n = try? c.decodeIfPresent(Int64.self, forKey: k) { return n }
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Int64(s) }
            return nil
        }
        init(planName: String?, teamsTier: String? = nil, monthlyPromptCredits: Int64? = nil, monthlyFlowCredits: Int64? = nil) {
            self.planName = planName; self.teamsTier = teamsTier
            self.monthlyPromptCredits = monthlyPromptCredits; self.monthlyFlowCredits = monthlyFlowCredits
        }
    }

    struct ModelQuota: Decodable, Equatable, Sendable {
        let label: String?
        let modelId: String?
        /// 0.0-1.0. Per proto3 zero-elision: when quotaInfo container exists
        /// but this field is absent, the value is 0 (exhausted). When the
        /// entire quotaInfo container is absent, set this nil (no limit).
        let remainingFraction: Double?
        let resetTime: Date?

        enum CodingKeys: String, CodingKey {
            case label, modelOrAlias, quotaInfo
        }
        enum AliasKeys: String, CodingKey { case model }
        enum QuotaKeys: String, CodingKey { case remainingFraction, resetTime }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.label = try c.decodeIfPresent(String.self, forKey: .label)
            if let alias = try? c.nestedContainer(keyedBy: AliasKeys.self, forKey: .modelOrAlias) {
                self.modelId = try alias.decodeIfPresent(String.self, forKey: .model)
            } else { self.modelId = nil }
            if let q = try? c.nestedContainer(keyedBy: QuotaKeys.self, forKey: .quotaInfo) {
                // quotaInfo container present
                self.remainingFraction = (try? q.decodeIfPresent(Double.self, forKey: .remainingFraction)) ?? 0
                if let s = try? q.decodeIfPresent(String.self, forKey: .resetTime) {
                    self.resetTime = ISO8601DateFormatter().date(from: s)
                } else { self.resetTime = nil }
            } else {
                // quotaInfo container absent — no rate limit
                self.remainingFraction = nil
                self.resetTime = nil
            }
        }
        init(label: String?, modelId: String?, remainingFraction: Double?, resetTime: Date?) {
            self.label = label; self.modelId = modelId
            self.remainingFraction = remainingFraction; self.resetTime = resetTime
        }
    }

    enum CodingKeys: String, CodingKey { case userStatus, schemaVersion }
    enum UserStatusKeys: String, CodingKey {
        case name, email, planStatus, cascadeModelConfigData, userTier
    }
    enum PlanStatusKeys: String, CodingKey {
        case planInfo, availablePromptCredits, availableFlowCredits
    }
    enum ModelConfigDataKeys: String, CodingKey { case clientModelConfigs }
    enum UserTierKeys: String, CodingKey { case availableCredits, name }

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: CodingKeys.self)
        self.fetchedAt = Date(timeIntervalSince1970: 0)
        self.schemaVersion = (try? outer.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
        guard let us = try? outer.nestedContainer(keyedBy: UserStatusKeys.self, forKey: .userStatus) else {
            self.name = nil; self.email = nil
            self.planInfo = nil
            self.availablePromptCredits = nil; self.availableFlowCredits = nil
            self.models = nil
            self.availableCredits = []
            self.userTierName = nil
            self.overagesEnabled = nil
            self.aiCreditsFallback = nil
            return
        }
        self.name = try us.decodeIfPresent(String.self, forKey: .name)
        self.email = (try us.decodeIfPresent(String.self, forKey: .email))?.lowercased()

        if let ps = try? us.nestedContainer(keyedBy: PlanStatusKeys.self, forKey: .planStatus) {
            self.planInfo = try ps.decodeIfPresent(PlanInfo.self, forKey: .planInfo)
            self.availablePromptCredits = try Self.flexibleInt64Outer(ps, .availablePromptCredits)
            self.availableFlowCredits = try Self.flexibleInt64Outer(ps, .availableFlowCredits)
        } else {
            self.planInfo = nil; self.availablePromptCredits = nil; self.availableFlowCredits = nil
        }

        if let md = try? us.nestedContainer(keyedBy: ModelConfigDataKeys.self, forKey: .cascadeModelConfigData) {
            self.models = try md.decodeIfPresent([ModelQuota].self, forKey: .clientModelConfigs)
        } else {
            self.models = nil
        }

        if let ut = try? us.nestedContainer(keyedBy: UserTierKeys.self, forKey: .userTier) {
            self.availableCredits = (try? ut.decodeIfPresent([WalletEntry].self, forKey: .availableCredits)) ?? []
            self.userTierName = try? ut.decodeIfPresent(String.self, forKey: .name)
        } else {
            self.availableCredits = []
            self.userTierName = nil
        }

        self.overagesEnabled = nil  // attached post-decode by AntigravityProvider
        self.aiCreditsFallback = nil  // attached post-decode by AntigravityProvider
    }

    init(
        fetchedAt: Date, name: String? = nil, email: String? = nil,
        planInfo: PlanInfo? = nil,
        availablePromptCredits: Int64? = nil, availableFlowCredits: Int64? = nil,
        models: [ModelQuota]? = nil, availableCredits: [WalletEntry] = [],
        userTierName: String? = nil,
        overagesEnabled: Bool? = nil,
        aiCreditsFallback: Int64? = nil,
        schemaVersion: Int = 1
    ) {
        self.fetchedAt = fetchedAt; self.name = name; self.email = email
        self.planInfo = planInfo
        self.availablePromptCredits = availablePromptCredits
        self.availableFlowCredits = availableFlowCredits
        self.models = models; self.availableCredits = availableCredits
        self.userTierName = userTierName
        self.overagesEnabled = overagesEnabled
        self.aiCreditsFallback = aiCreditsFallback
        self.schemaVersion = schemaVersion
    }

    private static func flexibleInt64Outer(_ c: KeyedDecodingContainer<PlanStatusKeys>, _ k: PlanStatusKeys) throws -> Int64? {
        if let n = try? c.decodeIfPresent(Int64.self, forKey: k) { return n }
        if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Int64(s) }
        return nil
    }

    static let decoder = JSONDecoder()

    // MARK: - Convenience

    /// Canonical plan-tier classification — drives the plan badge label
    /// and the AI Credits bar ceiling. See `AntigravityTier.detect`.
    var tier: AntigravityTier {
        AntigravityTier.detect(
            userTierName: userTierName,
            monthlyPromptCredits: planInfo?.monthlyPromptCredits
        )
    }

    /// First wallet entry's available balance, or `nil` when no wallet.
    /// Convenience used by the Usage tab, which currently renders only
    /// the first credit balance. Today the live endpoint returns exactly
    /// one entry (`creditType == "GOOGLE_ONE_AI"`); when multi-wallet
    /// surfaces in the wild, switch the view to iterate `availableCredits`.
    ///
    /// Falls back to `aiCreditsFallback` (read from state.vscdb) when the
    /// live API returns no wallet entry, so the AI Credits card — and the
    /// overage On/Off caption nested inside it — still render on an
    /// otherwise-healthy fetch that happened to omit the wallet.
    var aiCreditsWallet: Int64? { availableCredits.first?.creditAmount ?? aiCreditsFallback }

    /// Worst-among-still-usable utilization (0–100). Excludes models
    /// that are already exhausted (`remainingFraction == 0`) so the
    /// switcher bar reflects the headroom on a model the user can
    /// actually invoke — not a dead model with a tooltip pointing at
    /// "0% remaining". Special cases:
    ///
    /// - Returns `100` when every model with quota is exhausted: bar
    ///   renders fully capped (red) and tooltip surfaces the next reset.
    /// - Returns `nil` when no model carries quota information at all
    ///   (rate-limit fields absent in the live response).
    /// - When some models are exhausted and others are still usable,
    ///   returns the highest utilization AMONG the still-usable set.
    ///   The bar "switches" to a model with headroom; tooltip stays
    ///   plain ("Worst usable: <label> · N% remaining") — popover
    ///   carries the per-model breakdown for users who want detail.
    var worstModelUtilization: Double? {
        let modelsWithQuota = (models ?? []).filter { $0.remainingFraction != nil }
        guard !modelsWithQuota.isEmpty else { return nil }
        if allModelsExhausted { return 100 }
        let usable = modelsWithQuota.filter { ($0.remainingFraction ?? 0) > 0 }
        guard let minRemaining = usable.compactMap({ $0.remainingFraction }).min() else {
            return nil
        }
        return max(0, min(100, (1 - minRemaining) * 100))
    }

    /// The single model the "worst" surface points at. The bar label and
    /// the switcher reset both derive from this, so they can never disagree
    /// about which model they describe. Picks the worst-still-usable
    /// (lowest remaining) normally; when every model is exhausted, picks
    /// the one with the earliest `resetTime` (the next to come back online
    /// — the most actionable piece in the all-capped case). Nil when no
    /// model carries quota information (or, in the all-exhausted case, when
    /// none carries a `resetTime`).
    var worstModel: ModelQuota? {
        let modelsWithQuota = (models ?? []).filter { $0.remainingFraction != nil }
        guard !modelsWithQuota.isEmpty else { return nil }
        if allModelsExhausted {
            return modelsWithQuota
                .compactMap { m in m.resetTime.map { ($0, m) } }
                .min(by: { $0.0 < $1.0 })?
                .1
        }
        return modelsWithQuota
            .compactMap { m -> (Double, ModelQuota)? in
                guard let r = m.remainingFraction, r > 0 else { return nil }
                return (r, m)
            }
            .min(by: { $0.0 < $1.0 })?
            .1
    }

    /// Label of the model that drives `worstModelUtilization` — see
    /// `worstModel` for the selection rule.
    var worstModelLabel: String? { worstModel?.label }

    /// Reset time of the worst model — the one the switcher bar visualises.
    /// The switcher subtitle uses this so "Resets in …" describes the same
    /// model shown on the bar, not the soonest-resetting model overall
    /// (`earliestModelReset`). Nil when the worst model carries no reset
    /// window (e.g. every model fresh), letting the subtitle fall back to
    /// the credit cycle.
    var worstModelReset: Date? { worstModel?.resetTime }

    /// True when at least one model has quota data AND every such
    /// model is exhausted (`remainingFraction == 0`).
    var allModelsExhausted: Bool {
        let withQuota = (models ?? []).compactMap { $0.remainingFraction }
        guard !withQuota.isEmpty else { return false }
        return withQuota.allSatisfy { $0 == 0 }
    }

    /// True when at least one model has quota data AND every such
    /// model is at full headroom (`remainingFraction == 1`). Used by
    /// the tooltip to differentiate "fresh week" from "midway through".
    var allModelsFresh: Bool {
        let withQuota = (models ?? []).compactMap { $0.remainingFraction }
        guard !withQuota.isEmpty else { return false }
        return withQuota.allSatisfy { $0 >= 1 }
    }

    /// Earliest `resetTime` across models that carry one. Used to build
    /// "next reset in <time>" copy when every model is exhausted.
    var earliestModelReset: Date? {
        (models ?? []).compactMap { $0.resetTime }.min()
    }

    /// AI Credits utilization (0–100). nil when no wallet entry OR the
    /// current tier has no ceiling (Free / Unknown).
    var aiCreditsUtilization: Double? {
        guard let wallet = aiCreditsWallet,
              let ceiling = tier.aiCreditsCeiling, ceiling > 0
        else { return nil }
        return max(0, min(100, (1 - Double(wallet) / Double(ceiling)) * 100))
    }

    // MARK: - Reset cadence note
    //
    // The `GetUserStatus` endpoint does NOT expose a reset timestamp for
    // the Prompt / Flow credit pools. Only per-model `quotaInfo.resetTime`
    // (rate-limit cooldown for each model) is available, surfaced via
    // `ModelQuota.resetTime`. If a reset cadence for the credit pools is
    // needed in the UI, that information has to come from elsewhere
    // (a second endpoint, or hard-coded knowledge of the plan's cycle).

    /// Percent of the baseline prompt-credit window remaining (0-100).
    /// Antigravity's baseline quota is a rate-limit window, not a strict
    /// monthly pool drained to zero — when it hits 0 the user is downgraded
    /// to a smaller model rather than blocked. Reset cadence is determined
    /// server-side and not surfaced on this endpoint. Nil when plan absent.
    var promptCreditPercentRemaining: Double? {
        guard let avail = availablePromptCredits,
              let total = planInfo?.monthlyPromptCredits, total > 0
        else { return nil }
        return Double(avail) / Double(total) * 100
    }
    /// Percent of the baseline flow-credit window remaining (0-100).
    /// Flow credits are consumed by agentic tool-use steps and burn far
    /// faster than prompt credits during long-horizon agent loops. Same
    /// rate-limit-window semantics as `promptCreditPercentRemaining`.
    var flowCreditPercentRemaining: Double? {
        guard let avail = availableFlowCredits,
              let total = planInfo?.monthlyFlowCredits, total > 0
        else { return nil }
        return Double(avail) / Double(total) * 100
    }
}

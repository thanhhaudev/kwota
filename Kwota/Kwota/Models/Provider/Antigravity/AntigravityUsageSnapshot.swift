//
//  AntigravityUsageSnapshot.swift
//  Kwota
//
//  Decoded shape of GetUserStatus from the Antigravity language_server's
//  local Connect-RPC endpoint. Antigravity uses a credit-based quota model
//  with separate Prompt and Flow credit pools, plus an AI-credits wallet.
//  The authoritative per-group weekly/5h quota the app's "Model Quota" page
//  displays lives in RetrieveUserQuotaSummary (see AntigravityQuotaSummary),
//  not here — the per-model quotaInfo this used to parse measured a
//  different (internal) throttle and is no longer decoded.
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
            // actually drained. Proto3 zero-elision: a present container with
            // an omitted scalar means 0, not unknown.
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

    enum CodingKeys: String, CodingKey { case userStatus, schemaVersion }
    enum UserStatusKeys: String, CodingKey {
        case name, email, planStatus, userTier
    }
    enum PlanStatusKeys: String, CodingKey {
        case planInfo, availablePromptCredits, availableFlowCredits
    }
    enum UserTierKeys: String, CodingKey { case availableCredits, name }

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: CodingKeys.self)
        self.fetchedAt = Date(timeIntervalSince1970: 0)
        self.schemaVersion = (try? outer.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
        guard let us = try? outer.nestedContainer(keyedBy: UserStatusKeys.self, forKey: .userStatus) else {
            self.name = nil; self.email = nil
            self.planInfo = nil
            self.availablePromptCredits = nil; self.availableFlowCredits = nil
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
        availableCredits: [WalletEntry] = [],
        userTierName: String? = nil,
        overagesEnabled: Bool? = nil,
        aiCreditsFallback: Int64? = nil,
        schemaVersion: Int = 1
    ) {
        self.fetchedAt = fetchedAt; self.name = name; self.email = email
        self.planInfo = planInfo
        self.availablePromptCredits = availablePromptCredits
        self.availableFlowCredits = availableFlowCredits
        self.availableCredits = availableCredits
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
    // the Prompt / Flow credit pools. If a reset cadence for the credit
    // pools is needed in the UI, that information has to come from elsewhere
    // (a second endpoint, or hard-coded knowledge of the plan's cycle). The
    // authoritative per-group weekly/5h reset windows live in
    // `RetrieveUserQuotaSummary` — see `AntigravityQuotaSummary`.

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

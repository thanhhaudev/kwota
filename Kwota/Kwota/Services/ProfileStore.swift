//
//  ProfileStore.swift
//  Kwota
//

import Foundation
import Combine
import SwiftUI

@MainActor
@Observable
final class ProfileStore {
    enum StoreError: Error, Equatable {
        case unknownProfile(UUID)
        case identityMismatch(stored: String, response: String)
    }

    enum RemoveError: Error {
        /// The profile was successfully removed from the persisted list and from
        /// the in-memory store, but cleanup of side state (credentials and/or
        /// the on-disk history directory) failed. The profile will NOT reappear
        /// on next launch — but residual files may need manual removal. Surface
        /// this to the user via an alert so they know which paths to inspect.
        case sideStateLingered(profileId: UUID, keychainError: Error?, directoryError: Error?)
    }

    private(set) var profiles: [Profile] = []
    private(set) var activeProfileId: UUID? {
        didSet {
            guard oldValue != activeProfileId else { return }
            onActiveProfileChange?(activeProfileId)
        }
    }
    /// Set by `MenuBarViewModel` during init to drive `rebindHistory(for:)`.
    /// Replaces the prior `$activeProfileId` Combine pipeline now that this
    /// type is `@Observable` (no `$` projection available).
    @ObservationIgnored
    var onActiveProfileChange: ((UUID?) -> Void)?

    /// Fires after any mutation that changes the set of profile ids
    /// (add, remove, reorder). Renames do not fire this — they keep the
    /// same id. Set by `ShortcutCoordinator` to re-sync per-profile
    /// hotkey registrations.
    @ObservationIgnored
    var onProfilesChange: (() -> Void)?

    private let profilesFile: URL
    private let keychain: KeychainCredentialStore
    private let profileDirectoryProvider: (UUID) -> URL
    /// False after `load()` quarantines a corrupt `profiles.json`. While
    /// false, `save()` refuses to overwrite the empty in-memory state with
    /// an empty on-disk file — background auto-coordinator emits would
    /// otherwise destroy the user's recovery path. Cleared on the first
    /// `save()` after profiles becomes non-empty (the user added a profile,
    /// implicitly accepting the reset).
    private var loadedSuccessfully = true
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    private struct OnDisk: Codable {
        var profiles: [Profile]
        var activeProfileId: UUID?
    }

    init(
        profilesFile: URL = AppPaths.profilesFile,
        keychain: KeychainCredentialStore,
        profileDirectoryProvider: @escaping (UUID) -> URL = AppPaths.profileDirectory(id:)
    ) {
        self.profilesFile = profilesFile
        self.keychain = keychain
        self.profileDirectoryProvider = profileDirectoryProvider
        load()
    }

    /// Production profile store — wired to the production keychain service.
    /// Must NOT be used in tests; pass an explicit UUID-namespaced keychain
    /// instead (e.g. `ProfileStore(profilesFile:, keychain: makeKeychain(), ...)`).
    static func live() -> ProfileStore {
        ProfileStore(
            profilesFile: AppPaths.profilesFile,
            keychain: KeychainCredentialStore.live(),
            profileDirectoryProvider: AppPaths.profileDirectory(id:)
        )
    }

    var activeProfile: Profile? {
        guard let id = activeProfileId else { return nil }
        return profiles.first { $0.id == id }
    }

    /// All profiles backed by a specific provider, in display order.
    func profiles(for providerID: ProviderID) -> [Profile] {
        profiles.filter { $0.providerID == providerID }
    }

    /// Lookup-by-(providerID, email) for the dedup logic in the Add Profile
    /// flow. Provider-scoping prevents collisions when two providers have
    /// accounts with the same email.
    func findMatching(providerID: ProviderID, email: String?) -> Profile? {
        guard let email else { return nil }
        return profiles.first {
            $0.providerID == providerID
                && $0.email?.caseInsensitiveCompare(email) == .orderedSame
        }
    }

    /// Auto-detect lookup keyed on `(providerID, email, orgId)`. All three
    /// must match — a nil email or orgId returns nil to avoid coincidental
    /// matches on partial identity, and `providerID` scoping prevents the
    /// coordinator for one provider from activating a profile bound to
    /// another. Email comparison is case-insensitive; orgId is exact.
    func findMatching(providerID: ProviderID, email: String?, orgId: String?) -> Profile? {
        guard let email, let orgId else { return nil }
        return profiles.first {
            $0.providerID == providerID
                && $0.organizationId == orgId
                && $0.email?.caseInsensitiveCompare(email) == .orderedSame
        }
    }

    /// Email-only fallback lookup used by an auto-detect coordinator when
    /// the watcher cannot supply an orgId. Scoped to a single provider so
    /// a future second provider's profile sharing the same email is never
    /// returned to the wrong coordinator. Returns the first `.auto` profile
    /// matching both `providerID` and the case-insensitive email. Archived
    /// profiles are never returned — they're frozen history and must not be
    /// reused. nil/empty email returns nil.
    func findAutoByEmail(providerID: ProviderID, _ email: String?) -> Profile? {
        guard let email, !email.isEmpty else { return nil }
        return profiles.first {
            $0.providerID == providerID
                && $0.kind == .auto
                && $0.email?.caseInsensitiveCompare(email) == .orderedSame
        }
    }

    /// Mirror of `findAutoByEmail` but for archived profiles. Used by the
    /// auto-detect coordinator as the last cascade step so signing back into
    /// an account whose profile was archived on a previous logout reuses the
    /// archived profile (and promotes it to `.auto`) instead of creating a
    /// duplicate.
    func findArchivedByEmail(providerID: ProviderID, _ email: String?) -> Profile? {
        guard let email, !email.isEmpty else { return nil }
        return profiles.first {
            $0.providerID == providerID
                && $0.kind == .archived
                && $0.email?.caseInsensitiveCompare(email) == .orderedSame
        }
    }

    /// Migration helper for the /me-resolution upgrade path. Returns the
    /// unambiguous CLI-auth profile (auto OR archived) for `providerID`
    /// whose email matches case-insensitively AND whose `organizationId`
    /// is nil — i.e. a profile created during the nil-orgId era by the
    /// auto-detect coordinator. The coordinator uses this as the final
    /// cascade step when the watcher emits a non-nil orgId so legacy
    /// stored profiles get adopted instead of duplicated. The caller is
    /// expected to write the freshly-learned orgId onto the matched profile.
    ///
    /// Two guards keep the adoption from binding the new identity to the
    /// wrong profile:
    ///
    /// 1. `authMethod == .cliSync` — legacy wizard-era `.sessionKey`
    ///    profiles for the same email are NEVER adopted. Their identity
    ///    came from a paste-flow that pre-dates auto-detect, and writing
    ///    a CLI credential under their id would corrupt that boundary.
    /// 2. Exactly one candidate total (auto OR archived). When there are
    ///    multiple nil-org cliSync profiles with the same email, they
    ///    cannot be distinguished as duplicates vs. different workspaces.
    ///    A user who is a member of two team workspaces under the same
    ///    email can legitimately have profile A for org-A (auto) and
    ///    profile B for org-B (archived) — both nil-org until /me lands.
    ///    Preferring the auto candidate here would silently write the
    ///    newly-resolved org-B's identity onto profile A, corrupting A's
    ///    history. Refuse adoption when ambiguity exists and let the
    ///    caller create a fresh org-bound profile; user resolves the
    ///    duplicate manually with full org context visible.
    func findByEmailAwaitingOrg(providerID: ProviderID, _ email: String?) -> Profile? {
        guard let email, !email.isEmpty else { return nil }
        let candidates = profiles.filter {
            $0.providerID == providerID
                && $0.authMethod == .cliSync
                && $0.organizationId == nil
                && $0.email?.caseInsensitiveCompare(email) == .orderedSame
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    func add(_ profile: Profile) throws {
        profiles.append(profile)
        if activeProfileId == nil {
            activeProfileId = profile.id
        }
        try save()
        onProfilesChange?()
    }

    func rename(id: UUID, to newName: String) throws {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else {
            throw StoreError.unknownProfile(id)
        }
        profiles[idx].name = newName
        try save()
    }

    func setOrganizationId(_ orgId: String, for id: UUID) throws {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else {
            throw StoreError.unknownProfile(id)
        }
        profiles[idx].organizationId = orgId
        try save()
    }

    func updateProfile(_ profile: Profile) throws {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw StoreError.unknownProfile(profile.id)
        }
        profiles[idx] = profile
        try save()
    }

    /// Merges the latest `/api/oauth/profile` response into the stored
    /// profile for `id`. Returns `true` if any field changed (so the caller
    /// can log / update UI), `false` if every field already matched.
    ///
    /// Throws if persisting the change to disk fails. Callers that report
    /// success to the user (e.g. `MenuBarViewModel.refreshProfileMetadata`)
    /// MUST surface the throw rather than swallow it — otherwise the UI
    /// would say "Profile updated" while the next app launch reverts to
    /// the pre-probe state.
    ///
    /// Diff rule: a field is overwritten only when the response carries a
    /// non-nil value that differs from what's stored. This preserves the
    /// Guard A invariant: nil from a transient or degraded probe never wipes
    /// a previously-resolved value. `hasExtraUsageEnabled` follows the same
    /// rule now that `Response.hasExtraUsage` is `Bool?`.
    @discardableResult
    func apply(oauthProfile r: OAuthProfileFetcher.Response, for id: UUID) throws -> Bool {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return false }
        let target = profiles[idx]

        // Identity gate: refuse the entire merge if the response's stable
        // identity (orgUuid, accountUuid, email) conflicts with what's
        // stored. This prevents the same-email-multi-org contamination
        // path documented in Codex round 5: an email-only coordinator
        // match can route a different org's credential into an existing
        // profile and the probe response would otherwise silently rewrite
        // plan/account/billing/etc with the wrong account's data.
        //
        // A non-nil-vs-nil mismatch is NOT a conflict — that's the normal
        // first-probe backfill case. Conflict means BOTH sides have a
        // value AND they differ.
        if let storedOrg = target.organizationId,
           let respOrg = r.orgUuid, storedOrg != respOrg {
            throw StoreError.identityMismatch(
                stored: "org=\(storedOrg.prefix(8))",
                response: "org=\(respOrg.prefix(8))"
            )
        }
        if let storedAcc = target.accountUuid,
           let respAcc = r.accountUuid, storedAcc != respAcc {
            throw StoreError.identityMismatch(
                stored: "account=\(storedAcc.prefix(8))",
                response: "account=\(respAcc.prefix(8))"
            )
        }
        if let storedEmail = target.email,
           let respEmail = r.email,
           storedEmail.caseInsensitiveCompare(respEmail) != .orderedSame {
            throw StoreError.identityMismatch(
                stored: "email mismatch",
                response: "email mismatch"
            )
        }

        var updated = target
        var changed = false

        if let v = r.planLabel,            v != updated.subscriptionPlan        { updated.subscriptionPlan = v;        changed = true }
        if let v = r.subscriptionCreatedAt, v != updated.subscriptionCreatedAt  { updated.subscriptionCreatedAt = v;   changed = true }
        // organizationId: backfill ONLY when stored is nil. The
        // credential→profile binding is dynamic across CLI account
        // switches (an email-only coordinator match plus a seed-keychain
        // followed by this probe can route a different org's UUID into
        // an existing profile). A non-nil stored value is treated as the
        // authoritative org binding; cross-org corrections are the
        // coordinator's match-cascade responsibility, not this generic
        // apply path. See Codex adversarial review round 4.
        if updated.organizationId == nil, let v = r.orgUuid {
            updated.organizationId = v
            changed = true
        }
        if let v = r.accountUuid,          v != updated.accountUuid             { updated.accountUuid = v;             changed = true }
        if let v = r.displayName,          v != updated.displayName             { updated.displayName = v;             changed = true }
        if let v = r.accountCreatedAt,     v != updated.accountCreatedAt        { updated.accountCreatedAt = v;        changed = true }
        if let v = r.organizationName,     v != updated.organizationName        { updated.organizationName = v;        changed = true }
        if let v = r.subscriptionStatus,   v != updated.subscriptionStatus      { updated.subscriptionStatus = v;      changed = true }
        if let v = r.billingType,          v != updated.billingType             { updated.billingType = v;             changed = true }
        // hasExtraUsage now matches the Guard A rule: only overwrite when
        // the response carries a non-nil value that differs from stored.
        // A response that omits `has_extra_usage_enabled` (degraded payload
        // or schema skew) must NOT wipe a previously-resolved value.
        if let v = r.hasExtraUsage, v != updated.hasExtraUsageEnabled {
            updated.hasExtraUsageEnabled = v; changed = true
        }

        if changed {
            // Write-then-commit: only publish the new state if persistence
            // succeeds. Otherwise the @Observable `profiles` array would
            // hold values the disk does not, and downstream identity checks
            // (orgUuid/accountUuid gates in this same method on future
            // probes) would behave as if the backfill persisted while the
            // next app launch reverts to the pre-probe state. Codex
            // round 6 flagged this split-brain risk explicitly.
            let previous = profiles[idx]
            profiles[idx] = updated
            do {
                try save()
            } catch {
                profiles[idx] = previous
                throw error
            }
        }
        return changed
    }

    func setActive(id: UUID) throws {
        guard profiles.contains(where: { $0.id == id }) else {
            throw StoreError.unknownProfile(id)
        }
        activeProfileId = id
        try save()
    }

    /// Clears the active profile without removing any profile from the store.
    /// Used when the CLI signs out — profiles stay but no one is the live focus.
    func clearActive() throws {
        activeProfileId = nil
        try save()
    }

    /// Activates `id` on provider (re)appearance, but never steals focus from
    /// a *different* provider's live selection. Activates when nothing is
    /// active, when the active profile belongs to the same provider as `id`
    /// (the CLI switched accounts within that provider, so the old one is
    /// stale), or when `id` is already active. No-ops when a different
    /// provider owns the active profile. Returns whether `id` ended up active.
    @discardableResult
    func activateOnAppearance(id: UUID, provider: ProviderID) -> Bool {
        guard profiles.contains(where: { $0.id == id }) else { return false }
        if let activeId = activeProfileId,
           activeId != id,
           let active = profiles.first(where: { $0.id == activeId }),
           active.providerID != provider {
            return false                       // different provider live → keep it
        }
        try? setActive(id: id)
        return true
    }

    func move(fromId: UUID, toId: UUID) throws {
        guard let from = profiles.firstIndex(where: { $0.id == fromId }) else {
            throw StoreError.unknownProfile(fromId)
        }
        guard let to = profiles.firstIndex(where: { $0.id == toId }) else {
            throw StoreError.unknownProfile(toId)
        }
        guard from != to else { return }
        let item = profiles.remove(at: from)
        profiles.insert(item, at: to)
        try save()
        onProfilesChange?()
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) throws {
        profiles.move(fromOffsets: offsets, toOffset: destination)
        try save()
        onProfilesChange?()
    }

    func remove(id: UUID) throws {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else {
            throw StoreError.unknownProfile(id)
        }
        profiles.remove(at: idx)

        if activeProfileId == id {
            activeProfileId = profiles.first?.id
        }

        try save()
        onProfilesChange?()

        // Side-state cleanup happens AFTER save() so the profile is gone from
        // the user's perspective regardless of what fails here.
        var keychainError: Error?
        var directoryError: Error?
        do { try keychain.delete(for: id) } catch { keychainError = error }

        let dir = profileDirectoryProvider(id)
        if FileManager.default.fileExists(atPath: dir.path) {
            do { try FileManager.default.removeItem(at: dir) } catch { directoryError = error }
        }

        if keychainError != nil || directoryError != nil {
            throw RemoveError.sideStateLingered(
                profileId: id,
                keychainError: keychainError,
                directoryError: directoryError
            )
        }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: profilesFile.path) else { return }
        do {
            let data = try Data(contentsOf: profilesFile)
            let onDisk = try decoder.decode(OnDisk.self, from: data)
            self.profiles = onDisk.profiles
            self.activeProfileId = onDisk.activeProfileId
        // TODO(post-usage): surface corrupt-profiles event to user (log entry + one-shot UI banner). Currently silently quarantined.
        } catch {
            let backup = profilesFile.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: profilesFile, to: backup)
            loadedSuccessfully = false
            AppLog.shared.log(
                "ProfileStore: profiles.json failed to decode (\(error)). Quarantined to \(backup.lastPathComponent). Refusing background saves until profiles is non-empty.",
                level: .error
            )
        }
    }

    private func save() throws {
        // Quarantine guard: if load() failed and quarantined the file, refuse
        // to overwrite the empty in-memory state with an empty on-disk file.
        // Background auto-coordinator emits (CLIAccountWatcher → activate →
        // setActive → save) would otherwise destroy the user's recovery path
        // before they ever see the quarantine. The first `add()` populates
        // profiles, lifting the guard.
        if !loadedSuccessfully && profiles.isEmpty && activeProfileId == nil {
            AppLog.shared.log(
                "ProfileStore: refusing save() after corrupt-load quarantine (in-memory still empty)",
                level: .warn
            )
            return
        }
        let onDisk = OnDisk(profiles: profiles, activeProfileId: activeProfileId)
        let data = try encoder.encode(onDisk)
        try FileManager.default.createDirectory(
            at: profilesFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: profilesFile, options: .atomic)
        loadedSuccessfully = true
    }
}

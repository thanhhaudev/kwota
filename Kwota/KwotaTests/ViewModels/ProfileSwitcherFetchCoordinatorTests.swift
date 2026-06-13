//
//  ProfileSwitcherFetchCoordinatorTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class ProfileSwitcherFetchCoordinatorTests: XCTestCase {
    private func claudeProfile(_ email: String, id: UUID = UUID()) -> Profile {
        Profile(
            id: id, name: email, authMethod: .cliSync,
            providerID: .claude, email: email
        )
    }

    func test_initialState_isIdleForAllProfiles() {
        let c = ProfileSwitcherFetchCoordinator(fetcher: MockFetcher())
        XCTAssertEqual(c.row(for: UUID()), .idle)
    }

    func test_startFetching_skipsActiveProfileID() async {
        let active = claudeProfile("a@x.com")
        let other = claudeProfile("b@x.com")
        let fetcher = MockFetcher()
        fetcher.queue([
            other.id: .success(summary(.claude, primary: 0.5, secondary: 0.2))
        ])
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher)
        await c.startFetching(profiles: [active, other], skip: active.id)

        XCTAssertEqual(c.row(for: active.id), .idle)
        guard case let .loaded(s) = c.row(for: other.id) else {
            return XCTFail("expected .loaded for non-active profile")
        }
        XCTAssertEqual(s.primary?.utilization, 0.5)
        XCTAssertEqual(fetcher.callsFor(other.id), 1)
        XCTAssertEqual(fetcher.callsFor(active.id), 0)
    }

    func test_startFetching_transitionsThroughLoadingToLoaded() async {
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        let gate = MockFetcher.Gate()
        fetcher.queue([p.id: .gated(gate, .success(summary(.claude, primary: 0.1, secondary: 0.9)))])
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher)

        async let done: Void = c.startFetching(profiles: [p], skip: nil)
        // Deterministic: the fetch has entered the gate, so .loading is set.
        await gate.waitUntilEntered()
        XCTAssertEqual(c.row(for: p.id), .loading)
        gate.release()
        await done   // startFetching returns once the fetch resolves + apply() lands
        guard case .loaded = c.row(for: p.id) else {
            return XCTFail("expected .loaded after gate release")
        }
    }

    func test_startFetching_mapsThrownErrorToErrorState() async {
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        fetcher.queue([p.id: .failure(ProfileUsageFetcherError.missingCredential(profileID: p.id))])
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher)

        await c.startFetching(profiles: [p], skip: nil)
        guard case let .error(message) = c.row(for: p.id) else {
            return XCTFail("expected .error")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func test_repeatedStartFetching_doesNotRefetchLoadedRows() async {
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        fetcher.queue([p.id: .success(summary(.claude, primary: 0.5, secondary: 0.5))])
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher)

        await c.startFetching(profiles: [p], skip: nil)
        await c.startFetching(profiles: [p], skip: nil)

        XCTAssertEqual(fetcher.callsFor(p.id), 1)
    }

    // MARK: - Row SWR gate

    func test_startFetching_skipsFetch_whenLastSuccessfulIsFreshAfterReset() async {
        // Models the expand→collapse→expand pattern: reset() clears
        // `state` but `lastSuccessful` survives. With the SWR gate, a
        // second startFetching while the cached summary is still fresh
        // must NOT fire a network fetch.
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        fetcher.queueSequence([p.id: [
            .success(summary(.claude, primary: 0.5, secondary: 0.5,
                             fetchedAt: clock.addingTimeInterval(-5))),
            .success(summary(.claude, primary: 0.6, secondary: 0.6,
                             fetchedAt: clock)),
        ]])
        let c = ProfileSwitcherFetchCoordinator(
            fetcher: fetcher,
            rowFreshnessWindow: 60,
            now: { clock }
        )

        await c.startFetching(profiles: [p], skip: nil)
        XCTAssertEqual(fetcher.callsFor(p.id), 1, "first pass populates lastSuccessful")

        c.reset()  // mirrors collapse → expand from ProfileSwitcherCard.switchTo
        await c.startFetching(profiles: [p], skip: nil)

        XCTAssertEqual(
            fetcher.callsFor(p.id), 1,
            "cached row 5s old is inside the 60s SWR window — second pass must NOT refetch"
        )
    }

    func test_startFetching_fetchesAgain_whenLastSuccessfulIsStaleAfterReset() async {
        // Same setup as the skip test but with a stale cached fetchedAt;
        // the gate must fall through to a real refetch.
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        fetcher.queueSequence([p.id: [
            .success(summary(.claude, primary: 0.5, secondary: 0.5,
                             fetchedAt: clock.addingTimeInterval(-120))),
            .success(summary(.claude, primary: 0.6, secondary: 0.6,
                             fetchedAt: clock)),
        ]])
        let c = ProfileSwitcherFetchCoordinator(
            fetcher: fetcher,
            rowFreshnessWindow: 60,
            now: { clock }
        )

        await c.startFetching(profiles: [p], skip: nil)
        XCTAssertEqual(fetcher.callsFor(p.id), 1)

        c.reset()
        await c.startFetching(profiles: [p], skip: nil)

        XCTAssertEqual(
            fetcher.callsFor(p.id), 2,
            "cached row 120s old is outside the SWR window — second pass must refetch"
        )
    }

    func test_startFetching_refetchesFreshRow_whenCachedSummaryHasNoBucketData() async {
        // A degraded-but-successful fetch (e.g. Antigravity's quota
        // sub-fetch missed at cold start → both bars nil) must NOT be
        // treated as "fresh enough" by the SWR gate. Otherwise the empty
        // row sticks for the whole freshness window and only heals on a
        // manual profile switch (which seeds past the coordinator). A
        // cached summary with no bucket data always refetches so the row
        // self-heals on the next expand/poll.
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        fetcher.queueSequence([p.id: [
            .success(summary(.claude, primary: nil, secondary: nil,
                             fetchedAt: clock.addingTimeInterval(-5))),
            .success(summary(.claude, primary: 0.4, secondary: 0.3,
                             fetchedAt: clock)),
        ]])
        let c = ProfileSwitcherFetchCoordinator(
            fetcher: fetcher,
            rowFreshnessWindow: 60,
            now: { clock }
        )

        await c.startFetching(profiles: [p], skip: nil)
        XCTAssertEqual(fetcher.callsFor(p.id), 1, "first pass caches the empty (no-bucket) summary")

        c.reset()
        await c.startFetching(profiles: [p], skip: nil)

        XCTAssertEqual(
            fetcher.callsFor(p.id), 2,
            "cached row 5s old but with NO bucket data must refetch despite the SWR window"
        )
        guard case let .loaded(s) = c.row(for: p.id) else {
            return XCTFail("expected .loaded after the healing refetch")
        }
        XCTAssertEqual(s.primary?.utilization, 0.4)
    }

    func test_droppedProfile_evictsCachedSummary() async {
        // Models a profile being archived or removed while the popover
        // is open: a successful summary cached for that profile must
        // not survive into the next startFetching pass that no longer
        // lists it. Without eviction the cache would grow unbounded
        // and `row(for:)` could still return a `.loaded` for a profile
        // the user no longer owns.
        let a = claudeProfile("a@x.com")
        let b = claudeProfile("b@x.com")
        let fetcher = MockFetcher()
        fetcher.queue([
            a.id: .success(summary(.claude, primary: 0.1, secondary: 0.2)),
            b.id: .success(summary(.claude, primary: 0.3, secondary: 0.4)),
        ])
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher)

        await c.startFetching(profiles: [a, b], skip: nil)
        guard case .loaded = c.row(for: a.id) else {
            return XCTFail("setup: expected a to load on first pass")
        }

        // Now b is the only remaining profile — a was archived.
        // Re-prime fetcher so startFetching for [b] doesn't run dry.
        fetcher.queue([b.id: .success(summary(.claude, primary: 0.5, secondary: 0.6))])
        await c.startFetching(profiles: [b], skip: nil)

        XCTAssertEqual(c.row(for: a.id), .idle,
                       "evicted profile must return .idle, not its stale .loaded cache")
    }

    func test_explicitReset_thenStartFetching_refetchesPreviouslyLoadedRow() async {
        // Models the view's onChange(expanded: true) flow:
        // collapse → reset; expand → reset + startFetching. After an
        // explicit reset(), a previously-loaded row should be shown from
        // cache immediately and refreshed in the background. The SWR gate
        // is disabled here (`rowFreshnessWindow: 0`) so this test focuses
        // on the reset→refetch contract without being short-circuited by
        // the freshness check — covered by separate SWR-gate tests above.
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        let outcome: MockFetcher.Outcome = .success(summary(.claude, primary: 0.5, secondary: 0.5))
        fetcher.queue([p.id: outcome])
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher, rowFreshnessWindow: 0)

        await c.startFetching(profiles: [p], skip: nil)
        c.reset()
        // Re-prime the mock with a sequence of two outcomes so the new
        // startFetching can resolve deterministically (no race between
        // mock.pop and Task.yield).
        fetcher.queue([p.id: outcome])
        await c.startFetching(profiles: [p], skip: nil)
        guard case .loaded = c.row(for: p.id) else {
            return XCTFail("expected cached .loaded after reset + refetch")
        }

        XCTAssertEqual(fetcher.callsFor(p.id), 2)
    }

    func test_reset_clearsUncachedErrorState() async {
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        fetcher.queue([p.id: .failure(ProfileUsageFetcherError.missingCredential(profileID: p.id))])
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher)

        await c.startFetching(profiles: [p], skip: nil)
        guard case .error = c.row(for: p.id) else {
            return XCTFail("expected error before reset")
        }

        c.reset()

        XCTAssertEqual(c.row(for: p.id), .idle)
    }

    func test_transientFailedRefresh_keepsCachedRowAsStale() async {
        // Transient failures (network blip, 5xx, post-retry 401) must
        // preserve the cached summary — the point of the cache is to
        // ride through flaky network without flashing an error. SWR is
        // disabled (`rowFreshnessWindow: 0`) so the post-reset refetch
        // actually runs and surfaces the transient failure; otherwise the
        // freshness gate would skip the refetch and the row would never
        // hit the error→stale branch.
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher, rowFreshnessWindow: 0)
        fetcher.queue([p.id: .success(summary(.claude, primary: 0.5, secondary: 0.5))])
        await c.startFetching(profiles: [p], skip: nil)

        c.reset()
        // A generic NSError is not a ProfileUsageFetcherError, so it's
        // treated as transient — cache survives.
        let networkError = NSError(domain: "test.network", code: -1009, userInfo: nil)
        fetcher.queue([p.id: .failure(networkError)])
        await c.startFetching(profiles: [p], skip: nil)

        guard case let .stale(s) = c.row(for: p.id) else {
            return XCTFail("expected cached .stale after transient refresh failure")
        }
        XCTAssertEqual(s.primary?.utilization, 0.5)
    }

    func test_missingCredentialRefresh_evictsCacheAndShowsError() async {
        // Trust-boundary failure: the user revoked the CLI session for
        // this profile. The cache from before the revocation must not
        // keep masquerading as live data — fail closed. SWR is disabled
        // (`rowFreshnessWindow: 0`) so the post-reset refetch actually
        // runs and surfaces the trust-boundary error; the SWR semantics
        // are covered by dedicated tests above.
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher, rowFreshnessWindow: 0)
        fetcher.queue([p.id: .success(summary(.claude, primary: 0.5, secondary: 0.5))])
        await c.startFetching(profiles: [p], skip: nil)

        c.reset()
        fetcher.queue([p.id: .failure(ProfileUsageFetcherError.missingCredential(profileID: p.id))])
        await c.startFetching(profiles: [p], skip: nil)

        if case .loaded = c.row(for: p.id) {
            XCTFail("missingCredential must NOT resurrect the cached row — got .loaded")
        }
        if case .error = c.row(for: p.id) { /* ok */ } else {
            XCTFail("expected .error after missingCredential, got \(c.row(for: p.id))")
        }
    }

    func test_cliIdentityMismatchRefresh_evictsCacheAndShowsError() async {
        // Trust-boundary failure: the live CLI account no longer matches
        // this profile's recorded email. Showing stale .loaded would let
        // switchTo() preload the wrong account's usage into the header.
        // SWR is disabled (`rowFreshnessWindow: 0`) so the post-reset
        // refetch runs and surfaces the trust-boundary error; SWR
        // semantics are covered by dedicated tests above.
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher, rowFreshnessWindow: 0)
        fetcher.queue([p.id: .success(summary(.claude, primary: 0.5, secondary: 0.5))])
        await c.startFetching(profiles: [p], skip: nil)

        c.reset()
        fetcher.queue([p.id: .failure(ProfileUsageFetcherError.cliIdentityMismatch(profileID: p.id))])
        await c.startFetching(profiles: [p], skip: nil)

        if case .loaded = c.row(for: p.id) {
            XCTFail("cliIdentityMismatch must NOT resurrect the cached row — got .loaded")
        }
        if case .error = c.row(for: p.id) { /* ok */ } else {
            XCTFail("expected .error after cliIdentityMismatch, got \(c.row(for: p.id))")
        }
    }

    func test_unauthorizedFailure_retriesOnceBeforeSurfacingError() async {
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        fetcher.queueSequence([
            p.id: [
                .failure(ClaudeAPIClient.APIError.unauthorized),
                .success(summary(.claude, primary: 0.7, secondary: 0.2))
            ]
        ])
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher)

        await c.startFetching(profiles: [p], skip: nil)

        guard case let .loaded(s) = c.row(for: p.id) else {
            return XCTFail("expected retry to load row")
        }
        XCTAssertEqual(s.primary?.utilization, 0.7)
        XCTAssertEqual(fetcher.callsFor(p.id), 2)
    }

    func test_reset_clearsAllRowState_and_cancelsInFlight() async {
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        let gate = MockFetcher.Gate()
        fetcher.queue([p.id: .gated(gate, .success(summary(.claude, primary: 0.5, secondary: 0.5)))])
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher)

        async let done: Void = c.startFetching(profiles: [p], skip: nil)
        // Deterministic sequencing: waiting for the fetch to enter the gate
        // guarantees startFetching has set .loading AND registered the in-flight
        // task, so reset() cancels a real task. Yield-counting raced here — if
        // reset() ran before the task was registered, the gated fetch later
        // completed and apply(.loaded) clobbered the expected .idle.
        await gate.waitUntilEntered()
        XCTAssertEqual(c.row(for: p.id), .loading)
        c.reset()
        gate.release()
        await done   // startFetching returns once the cancelled fetch drains
        XCTAssertEqual(c.row(for: p.id), .idle)
    }

    // MARK: - Transient cold-start retry

    func test_transientNoCacheRetry_succeedsOnSecondAttempt() async {
        // Cold-start scenario: no prior cache, first fetch hits a
        // transient error (network blip, slow OAuth refresh), second
        // attempt succeeds. The coordinator must hide the first failure
        // entirely — the row never reaches `.error`.
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        let networkError = NSError(domain: "test.network", code: -1009, userInfo: nil)
        fetcher.queueSequence([
            p.id: [
                .failure(networkError),
                .success(summary(.claude, primary: 0.42, secondary: 0.6))
            ]
        ])
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher)

        await c.startFetching(profiles: [p], skip: nil)

        guard case let .loaded(s) = c.row(for: p.id) else {
            return XCTFail("expected retry to load row, got \(c.row(for: p.id))")
        }
        XCTAssertEqual(s.primary?.utilization, 0.42)
        XCTAssertEqual(fetcher.callsFor(p.id), 2,
                       "first attempt + one retry = 2 fetcher calls")
    }

    func test_transientNoCacheRetry_exhaustsToError() async {
        // Both attempts fail transiently. With no cache to fall back on,
        // the row finally surfaces .error.
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        let networkError = NSError(domain: "test.network", code: -1009, userInfo: nil)
        fetcher.queueSequence([
            p.id: [
                .failure(networkError),
                .failure(networkError)
            ]
        ])
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher)

        await c.startFetching(profiles: [p], skip: nil)

        if case .error = c.row(for: p.id) { /* expected */ } else {
            XCTFail("expected .error after retry exhausted, got \(c.row(for: p.id))")
        }
        XCTAssertEqual(fetcher.callsFor(p.id), 2,
                       "first attempt + one retry = 2 fetcher calls")
    }

    func test_trustBoundaryError_doesNotRetry() async {
        // Trust-boundary errors are deterministic — retrying just
        // duplicates the failure. The coordinator must propagate the
        // first occurrence immediately and not consume a second outcome
        // from the mock.
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        fetcher.queueSequence([
            p.id: [
                .failure(ProfileUsageFetcherError.missingCredential(profileID: p.id)),
                .success(summary(.claude, primary: 0.9, secondary: 0.1))
            ]
        ])
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher)

        await c.startFetching(profiles: [p], skip: nil)

        if case .error = c.row(for: p.id) { /* expected */ } else {
            XCTFail("expected .error after trust-boundary failure, got \(c.row(for: p.id))")
        }
        XCTAssertEqual(fetcher.callsFor(p.id), 1,
                       "trust-boundary must NOT consume the second outcome")
    }

    // MARK: - Rate-limit handling

    func test_rateLimitedSurfacesErrorWithoutRetry() async {
        // A 429 on a switcher row means the bucket is exhausted. Retrying
        // from here would just multiply post-429 traffic across all N-1
        // rows. The coordinator must surface .error after one fetch and
        // leave the recovery to the shared back-off floor.
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        fetcher.queueSequence([
            p.id: [
                .failure(ClaudeAPIClient.APIError.rateLimited(retryAfter: 1)),
                .success(summary(.claude, primary: 0.4, secondary: 0.6))
            ]
        ])
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher)

        await c.startFetching(profiles: [p], skip: nil)

        if case .error = c.row(for: p.id) { /* expected */ } else {
            XCTFail("expected .error after 429, got \(c.row(for: p.id))")
        }
        XCTAssertEqual(fetcher.callsFor(p.id), 1,
                       "429 must not consume the second outcome — no in-coordinator retry")
    }

    func test_rateLimitedRowFiresOnRowRateLimitedWithRetryAfter() async {
        // When a row hits 429 with a usable Retry-After, the coordinator
        // hands the value to the host (MenuBarViewModel pumps it into
        // refreshCoordinator.applyRetryAfter so both paths share one
        // back-off floor).
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        fetcher.queue([p.id: .failure(ClaudeAPIClient.APIError.rateLimited(retryAfter: 42))])
        var captured: [(ProviderID, TimeInterval?)] = []
        let c = ProfileSwitcherFetchCoordinator(
            fetcher: fetcher,
            onRowRateLimited: { providerID, retryAfter in captured.append((providerID, retryAfter)) }
        )

        await c.startFetching(profiles: [p], skip: nil)

        XCTAssertEqual(captured.count, 1, "expected exactly one callback fire")
        XCTAssertEqual(captured.first?.0, .claude)
        XCTAssertEqual(captured.first?.1, 42)
    }

    func test_rateLimitedRowFiresCallbackEvenWhenRetryAfterIsNil() async {
        // 429 without Retry-After still propagates — host can substitute
        // a default value.
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        fetcher.queue([p.id: .failure(ClaudeAPIClient.APIError.rateLimited(retryAfter: nil))])
        var captured: [(ProviderID, TimeInterval?)] = []
        let c = ProfileSwitcherFetchCoordinator(
            fetcher: fetcher,
            onRowRateLimited: { providerID, retryAfter in captured.append((providerID, retryAfter)) }
        )

        await c.startFetching(profiles: [p], skip: nil)

        XCTAssertEqual(captured.count, 1)
        guard let first = captured.first else { return XCTFail("expected callback fire") }
        XCTAssertEqual(first.0, .claude)
        XCTAssertNil(first.1, "Retry-After omitted by server should propagate as nil")
    }

    // MARK: - Shared back-off (active → switcher)

    func test_externallyBackingOff_skipsFetchAndLeavesCachedRowLoaded() async {
        // Active path is in 429 back-off. A cached switcher row must
        // stay visible as .loaded(cached) and NOT issue a network call —
        // the shared bucket is exhausted.
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        fetcher.queueSequence([p.id: [
            .success(summary(.claude, primary: 0.5, secondary: 0.5,
                             fetchedAt: clock.addingTimeInterval(-120))),
            .success(summary(.claude, primary: 0.9, secondary: 0.9,
                             fetchedAt: clock)),
        ]])
        // First pass without back-off populates the cache (intentionally
        // outside the freshness window so a vanilla second pass would
        // refetch).
        let c = ProfileSwitcherFetchCoordinator(
            fetcher: fetcher,
            rowFreshnessWindow: 60,
            now: { clock },
            isExternallyBackingOff: { _ in false }
        )
        await c.startFetching(profiles: [p], skip: nil)
        XCTAssertEqual(fetcher.callsFor(p.id), 1)

        // Flip the back-off predicate by recreating the coordinator
        // with the same in-memory cache (mirrors a separate run with
        // back-off active — simplest seam without exposing a setter).
        let c2 = ProfileSwitcherFetchCoordinator(
            fetcher: fetcher,
            rowFreshnessWindow: 60,
            now: { clock },
            isExternallyBackingOff: { _ in true }
        )
        // Inject the same cached summary the first pass produced so the
        // back-off-pass starts with a populated cache.
        c2.seedLastSuccessfulForTests([p.id: summary(.claude, primary: 0.5, secondary: 0.5,
                                                     fetchedAt: clock.addingTimeInterval(-120))])
        c2.reset()  // clear any state; cache remains
        await c2.startFetching(profiles: [p], skip: nil)

        XCTAssertEqual(fetcher.callsFor(p.id), 1,
                       "external back-off must prevent the refetch even though the cached row is stale")
        guard case .loaded = c2.row(for: p.id) else {
            return XCTFail("cached row must stay visible as .loaded while backing off — got \(c2.row(for: p.id))")
        }
    }

    func test_firstRow429_preventsSiblingRowsFromFetching() async {
        // Sibling-burst race: with the previous concurrent task-group
        // scheduling, every row in `toFetch` fired its network request
        // before any sibling's 429 had a chance to set the shared
        // back-off. Now that fetches are serialized and the predicate
        // is re-checked between rows, the first row's 429 must stop
        // the rest of the burst from hitting the same exhausted bucket.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var sharedBackoffUntil: Date? = nil
        let a = claudeProfile("a@x.com")
        let b = claudeProfile("b@x.com")
        let cProfile = claudeProfile("c@x.com")
        let fetcher = MockFetcher()
        fetcher.queue([
            a.id: .failure(ClaudeAPIClient.APIError.rateLimited(retryAfter: 60)),
            b.id: .success(summary(.claude, primary: 0.5, secondary: 0.5)),
            cProfile.id: .success(summary(.claude, primary: 0.6, secondary: 0.6)),
        ])
        let coord = ProfileSwitcherFetchCoordinator(
            fetcher: fetcher,
            now: { now },
            onRowRateLimited: { _, retryAfter in
                sharedBackoffUntil = now.addingTimeInterval(retryAfter ?? 60)
            },
            isExternallyBackingOff: { _ in
                (sharedBackoffUntil ?? .distantPast) > now
            }
        )

        await coord.startFetching(profiles: [a, b, cProfile], skip: nil)

        XCTAssertEqual(fetcher.callsFor(a.id), 1,
                       "first row fetches and discovers the 429")
        XCTAssertEqual(fetcher.callsFor(b.id), 0,
                       "after the first row's 429 set the shared floor, sibling row B must NOT issue a network call")
        XCTAssertEqual(fetcher.callsFor(cProfile.id), 0,
                       "after the first row's 429 set the shared floor, sibling row C must NOT issue a network call")
    }

    func test_externallyBackingOff_skipsFetchAndSurfacesErrorForUncachedRow() async {
        // Active path is backing off and there is no cached entry. The
        // row must NOT show a stuck spinner — surface .error so the
        // user knows refresh is paused.
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        // No outcome queued — if fetch ever fires the mock would throw.
        let c = ProfileSwitcherFetchCoordinator(
            fetcher: fetcher,
            isExternallyBackingOff: { _ in true }
        )

        await c.startFetching(profiles: [p], skip: nil)

        XCTAssertEqual(fetcher.callsFor(p.id), 0,
                       "external back-off must prevent the fetch entirely")
        if case .error = c.row(for: p.id) { /* expected */ } else {
            XCTFail("expected .error for uncached row while backing off, got \(c.row(for: p.id))")
        }
    }

    // MARK: - Degraded-but-successful retention

    func test_emptyRefetch_retainsLastGoodSnapshot() async {
        // Codex's wham/usage intermittently returns HTTP 200 with
        // `rate_limit: null`, decoding to a valid summary whose bars are
        // both empty. A second fetch returning that must NOT blank a row
        // that previously loaded real data.
        let p = Profile(
            id: UUID(), name: "c@x.com", authMethod: .cliSync,
            providerID: .codex, email: "c@x.com"
        )
        let fetcher = MockFetcher()
        fetcher.queueSequence([p.id: [
            .success(summary(.codex, primary: 12, secondary: 34)),
            .success(summary(.codex, primary: nil, secondary: nil))
        ]])
        // rowFreshnessWindow 0 so the second startFetching refetches rather
        // than short-circuiting on the SWR freshness gate.
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher, rowFreshnessWindow: 0)

        await c.startFetching(profiles: [p], skip: nil)
        guard case let .loaded(first) = c.row(for: p.id) else {
            return XCTFail("expected first fetch to load, got \(c.row(for: p.id))")
        }
        XCTAssertEqual(first.primary?.utilization, 12)

        // reset() clears transient row state but keeps lastSuccessful, so
        // the next startFetching issues a fresh fetch — which returns empty.
        c.reset()
        await c.startFetching(profiles: [p], skip: nil)

        XCTAssertEqual(fetcher.callsFor(p.id), 2, "the empty second fetch must have fired")
        guard case let .stale(after) = c.row(for: p.id) else {
            return XCTFail("row must stay loaded after empty refetch, got \(c.row(for: p.id))")
        }
        XCTAssertEqual(after.primary?.utilization, 12, "empty refetch must not clobber last good data")
        XCTAssertEqual(after.secondary?.utilization, 34)
    }

    func test_seed_fillsAbsentRowAsLoaded() {
        let p = claudeProfile("a@x.com")
        let c = ProfileSwitcherFetchCoordinator(fetcher: MockFetcher())
        let s = summary(.claude, primary: 0.3, secondary: 0.4)
        c.seed([p.id: s])
        guard case let .loaded(got) = c.row(for: p.id) else {
            return XCTFail("expected seeded row to read as .loaded")
        }
        XCTAssertEqual(got.fetchedAt, s.fetchedAt)
    }

    func test_seed_doesNotDowngradeFresherFetchedRow() async {
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        let fresh = summary(.claude, primary: 0.5, secondary: 0.5,
                            fetchedAt: Date(timeIntervalSince1970: 2000))
        fetcher.queue([p.id: .success(fresh)])
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher)
        await c.startFetching(profiles: [p], skip: nil)   // lastSuccessful[p] = fresh

        let older = summary(.claude, primary: 0.1, secondary: 0.1,
                            fetchedAt: Date(timeIntervalSince1970: 1000))
        c.seed([p.id: older])   // older than the fetched row → must be ignored

        guard case let .loaded(got) = c.row(for: p.id) else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(got.fetchedAt, fresh.fetchedAt,
                       "seed must not downgrade a fresher fetched row")
    }

    func test_seededRow_transientFailure_showsStaleNotError() async {
        let p = claudeProfile("a@x.com")
        let fetcher = MockFetcher()
        let c = ProfileSwitcherFetchCoordinator(fetcher: fetcher, rowFreshnessWindow: 0)
        let seeded = summary(.claude, primary: 0.5, secondary: 0.5,
                             fetchedAt: Date(timeIntervalSince1970: 1000))
        c.seed([p.id: seeded])   // recently-active profile, never fetched as a row

        fetcher.queue([p.id: .failure(ClaudeAPIClient.APIError.rateLimited(retryAfter: 60))])
        await c.startFetching(profiles: [p], skip: nil)

        guard case let .stale(got) = c.row(for: p.id) else {
            return XCTFail("expected .stale fallback, got \(c.row(for: p.id))")
        }
        XCTAssertEqual(got.fetchedAt, seeded.fetchedAt)
    }

    func test_rowFetch_staleEqualityMatchesLoadedSemantics() {
        let a = summary(.claude, primary: 0.5, secondary: 0.5,
                        fetchedAt: Date(timeIntervalSince1970: 1))
        let b = summary(.claude, primary: 0.9, secondary: 0.1,
                        fetchedAt: Date(timeIntervalSince1970: 1))
        // Equality is providerID + fetchedAt only (payload is not Equatable).
        XCTAssertEqual(
            ProfileSwitcherFetchCoordinator.RowFetch.stale(a),
            ProfileSwitcherFetchCoordinator.RowFetch.stale(b)
        )
        XCTAssertNotEqual(
            ProfileSwitcherFetchCoordinator.RowFetch.stale(a),
            ProfileSwitcherFetchCoordinator.RowFetch.loaded(a)
        )
    }

    // MARK: - Helpers

    private func summary(_ providerID: ProviderID, primary: Double?, secondary: Double?, fetchedAt: Date = Date()) -> ProviderUsageSummary {
        ProviderUsageSummary(
            providerID: providerID,
            fetchedAt: fetchedAt,
            primary: UsageBucket(utilization: primary, resetsAt: nil),
            secondary: UsageBucket(utilization: secondary, resetsAt: nil),
            payload: UsageSnapshot.zeroes()
        )
    }
}

@MainActor
private final class MockFetcher: ProfileUsageFetching {
    indirect enum Outcome {
        case success(ProviderUsageSummary)
        case failure(Error)
        case gated(Gate, Outcome)
    }

    final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var entered = false

        func wait() async {
            // Signal that the gated fetch is now in-flight so a test can
            // deterministically sequence reset()/release() instead of guessing
            // with Task.yield() counts.
            entered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            if released { return }
            await withCheckedContinuation { c in self.continuation = c }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
        /// Resolves once a fetch has entered `wait()` — i.e. the coordinator has
        /// already set the row to .loading and registered the in-flight task.
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { c in self.enteredContinuation = c }
        }
    }

    private var queued: [UUID: [Outcome]] = [:]
    private var calls: [UUID: Int] = [:]

    func queue(_ outcomes: [UUID: Outcome]) {
        queued.merge(outcomes.mapValues { [$0] }) { _, new in new }
    }
    func queueSequence(_ outcomes: [UUID: [Outcome]]) {
        queued.merge(outcomes) { _, new in new }
    }
    func callsFor(_ id: UUID) -> Int { calls[id] ?? 0 }

    func fetch(profile: Profile) async throws -> ProviderUsageSummary {
        calls[profile.id, default: 0] += 1
        guard var outcomes = queued[profile.id], !outcomes.isEmpty else {
            throw NSError(domain: "MockFetcher", code: 0, userInfo: [NSLocalizedDescriptionKey: "no outcome queued for \(profile.id)"])
        }
        let outcome = outcomes.removeFirst()
        queued[profile.id] = outcomes
        return try await resolve(outcome)
    }

    private func resolve(_ outcome: Outcome) async throws -> ProviderUsageSummary {
        switch outcome {
        case .success(let s): return s
        case .failure(let e): throw e
        case .gated(let gate, let inner):
            await gate.wait()
            return try await resolve(inner)
        }
    }
}

//
//  CodexAPIClient.swift
//  Kwota
//
//  Single endpoint: GET chatgpt.com/backend-api/wham/usage with Bearer auth.
//  Error vocabulary is borrowed from ClaudeAPIClient.APIError so the
//  shell's existing 401 / 429 / transient catch blocks work for both
//  providers without further plumbing.
//

import Foundation

final class CodexAPIClient {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    let transport: ClaudeAPIClient.Transport
    let now: () -> Date

    init(
        transport: @escaping ClaudeAPIClient.Transport,
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.now = now
    }

    /// Production transport — uses URLSession.shared. Tests pass a stub
    /// closure to init(transport:).
    static func live(now: @escaping () -> Date = Date.init) -> CodexAPIClient {
        CodexAPIClient(
            transport: { try await URLSession.shared.data(for: $0) },
            now: now
        )
    }

    /// Fetches and decodes `wham/usage`. Stamps `snapshot.fetchedAt` with
    /// the current time so callers can append to the history store.
    func fetchSnapshot(credential: Credential) async throws -> CodexUsageSnapshot {
        guard case .cliToken(let accessToken, _, _) = credential else {
            throw ClaudeAPIClient.APIError.unauthorized
        }
        var req = URLRequest(url: Self.usageURL)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(
            "Kwota/0.1 (+https://github.com/thanhhaudev/kwota)",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await transport(req)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeAPIClient.APIError.http(status: -1)
        }
        switch http.statusCode {
        case 200...299:
            var snap: CodexUsageSnapshot
            do {
                snap = try CodexUsageSnapshot.decoder.decode(CodexUsageSnapshot.self, from: data)
            } catch {
                throw ClaudeAPIClient.APIError.decode(String(describing: error))
            }
            snap.fetchedAt = now()
            return snap
        case 401, 403:
            throw ClaudeAPIClient.APIError.unauthorized
        case 429:
            throw ClaudeAPIClient.APIError.rateLimited(retryAfter: Self.parseRetryAfter(http))
        default:
            throw ClaudeAPIClient.APIError.http(status: http.statusCode)
        }
    }

    /// Parses `Retry-After` (seconds — RFC 7231 also allows HTTP-date but
    /// Codex always sends seconds today). Returns nil when missing / unparseable.
    private static func parseRetryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        guard
            let raw = http.value(forHTTPHeaderField: "Retry-After")
                ?? http.value(forHTTPHeaderField: "retry-after"),
            let seconds = Double(raw),
            seconds > 0
        else {
            return nil
        }
        return seconds
    }
}

//
//  AntigravityAPIClient.swift
//  Kwota
//
//  Talks to the Antigravity language_server's local Connect-RPC endpoint.
//  Pattern: same as CodexAPIClient/ClaudeAPIClient (transport closure
//  injected for tests). Probes both HTTP and HTTPS on each candidate port
//  until one returns 200. Errors map onto ClaudeAPIClient.APIError so the
//  shell's 401/429/transient catch blocks work without further plumbing —
//  even though we never expect 401 here (CSRF either works or returns 200
//  with an error code in the JSON body).
//

import Foundation

final class AntigravityAPIClient {
    /// The Connect-RPC method path. Stable for now; if it ever changes,
    /// this is the one constant to update.
    static let methodPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"

    /// RetrieveUserQuotaSummary — the authoritative per-group weekly/5h quota.
    static let quotaMethodPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"

    /// Shared request body — the metadata envelope both endpoints accept.
    static let requestBody = #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}"#

    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    let transport: Transport
    let now: () -> Date

    init(transport: @escaping Transport, now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.now = now
    }

    /// Production transport — uses an ephemeral URLSession that accepts the
    /// language_server's self-signed certificate for the loopback host.
    /// Tests inject a stub via init(transport:). See `ClaudeAPIClient.live`
    /// for why the closure must be explicitly `@Sendable` (off-MainActor
    /// bridge).
    static func live(now: @escaping () -> Date = Date.init) -> AntigravityAPIClient {
        let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { req in
            try await Self.permissiveSession.data(for: req)
        }
        return AntigravityAPIClient(transport: transport, now: now)
    }

    /// URLSession that accepts ANY server certificate ONLY when the host is
    /// 127.0.0.1. Loopback has no MITM surface, so this is safe; the host
    /// guard is defense-in-depth in case URLSession ever starts following
    /// redirects to non-loopback destinations.
    private static let permissiveSession: URLSession = {
        let delegate = LoopbackPermissiveDelegate()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }()

    private final class LoopbackPermissiveDelegate: NSObject, URLSessionDelegate {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.host == "127.0.0.1",
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    /// Fetches the snapshot by trying HTTP first then HTTPS on the given
    /// port until one returns a 200 with valid JSON. HTTP-first avoids the
    /// TLS handshake on the common case; HTTPS is the fallback for builds
    /// where only the TLS port is open.
    ///
    /// Errors:
    /// - `.decode(...)` on 200 with malformed JSON (does NOT fall through —
    ///   a 200 means we found the server, so a parse failure is fatal).
    /// - `.transient` when neither scheme returns a 200 (connection refused,
    ///   non-200 status on both, network error on both).
    func fetchSnapshot(port: Int, csrfToken: String) async throws -> AntigravityUsageSnapshot {
        let data = try await postFirst200(port: port, csrfToken: csrfToken, methodPath: Self.methodPath)
        var snap: AntigravityUsageSnapshot
        do {
            snap = try AntigravityUsageSnapshot.decoder.decode(AntigravityUsageSnapshot.self, from: data)
        } catch {
            AppLog.shared.log(
                "AntigravityAPIClient.decode snapshot failed: \(data.count) bytes (body redacted)",
                level: .debug)
            throw ClaudeAPIClient.APIError.decode(String(describing: error))
        }
        snap.fetchedAt = now()
        return snap
    }

    func fetchQuotaSummary(port: Int, csrfToken: String) async throws -> AntigravityQuotaSummary {
        let data = try await postFirst200(port: port, csrfToken: csrfToken, methodPath: Self.quotaMethodPath)
        var quota: AntigravityQuotaSummary
        do {
            quota = try AntigravityQuotaSummary.decoder.decode(AntigravityQuotaSummary.self, from: data)
        } catch {
            AppLog.shared.log(
                "AntigravityAPIClient.decode quota failed: \(data.count) bytes (body redacted)",
                level: .debug)
            throw ClaudeAPIClient.APIError.decode(String(describing: error))
        }
        quota.fetchedAt = now()
        return quota
    }

    /// Shared scheme-probe: POST to the given RPC method path over http then
    /// https; return the body of the first 200. A 200 with a bad body is the
    /// caller's problem (decode there) — finding a 200 means we found the
    /// server. `.transient` when neither scheme yields a 200.
    private func postFirst200(port: Int, csrfToken: String, methodPath: String) async throws -> Data {
        for scheme in ["http", "https"] {
            guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(methodPath)") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            req.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
            req.httpBody = Data(Self.requestBody.utf8)

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await transport(req)
            } catch {
                continue
            }
            guard let http = response as? HTTPURLResponse else { continue }
            if http.statusCode == 200 { return data }
        }
        throw ClaudeAPIClient.APIError.transient
    }
}

//
//  URLProtocolNetGuard.swift
//  KwotaTests
//
//  URLProtocol subclass that fails any non-file:// request. Installed
//  globally by KwotaTestCase.setUp() so accidental real-network calls
//  inside tests are turned into XCTFail + URLError rather than silent
//  hits against claude.ai or similar.
//
//  Limitation: only catches traffic that goes through URLSession (the
//  default config or any session built from URLSessionConfiguration.default).
//  Code paths that use Process / raw sockets / a different HTTP library
//  are NOT intercepted.
//

import Foundation
import XCTest

final class URLProtocolNetGuard: URLProtocol {

    private static let lock = NSLock()
    private static var installCount = 0

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        if installCount == 0 {
            URLProtocol.registerClass(URLProtocolNetGuard.self)
        }
        installCount += 1
    }

    static func uninstall() {
        lock.lock()
        defer { lock.unlock() }
        installCount = max(0, installCount - 1)
        if installCount == 0 {
            URLProtocol.unregisterClass(URLProtocolNetGuard.self)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme != "file" && scheme != "data"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let urlString = request.url?.absoluteString ?? "<no url>"
        XCTFail("URLProtocolNetGuard: real network request blocked — \(urlString). Tests must use a stub Transport.")
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}

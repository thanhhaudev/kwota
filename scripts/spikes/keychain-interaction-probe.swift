// scripts/spikes/keychain-interaction-probe.swift
// Usage: kcprobe none | legacy | modern
import Foundation
import Security

let service = "Claude Code-credentials"
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "none"

var query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
]

switch mode {
case "legacy":
    SecKeychainSetUserInteractionAllowed(false)
case "modern":
    query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
default:
    break
}

let started = Date()
var result: AnyObject?
let status = SecItemCopyMatching(query as CFDictionary, &result)
let elapsed = Date().timeIntervalSince(started)

let bytes = (result as? Data)?.count ?? -1
print("mode=\(mode) status=\(status) elapsedSeconds=\(String(format: "%.2f", elapsed)) byteCount=\(bytes)")
print("errSecInteractionNotAllowed would be \(errSecInteractionNotAllowed)")

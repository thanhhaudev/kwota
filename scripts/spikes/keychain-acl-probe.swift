// scripts/spikes/keychain-acl-probe.swift
// Usage: aclprobe [service]        default: "Claude Code-credentials"
//   swiftc -o /tmp/aclprobe scripts/spikes/keychain-acl-probe.swift
//
// Answers "which applications are trusted on this keychain item, by full
// path" — the question Keychain Access cannot answer, because its Access
// Control tab shows only each entry's *name*. Nine different Kwota builds all
// render there as nine rows called "Kwota", so a list can look reassuring
// while the app you actually run is absent from it. That is precisely how the
// 2026-08-06 stale-popover incident stayed hidden; see
// docs/findings/F-005-keychain-interaction-suppression.md.
//
// Reads the ACL WITHOUT reading the item's data: kSecReturnRef, never
// kSecReturnData, so nothing is decrypted and the XARA consent dialog has no
// reason to fire. Interaction is disabled up front regardless, so if some path
// did want a prompt it fails fast rather than parking a thread on a dialog
// nobody is watching — the failure mode this whole area exists to avoid.
import Foundation
import Security

let service = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Claude Code-credentials"

SecKeychainSetUserInteractionAllowed(false)

var item: CFTypeRef?
let status = SecItemCopyMatching([
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecReturnRef as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
] as CFDictionary, &item)

guard status == errSecSuccess, let item else {
    print("LOOKUP FAILED status=\(status)")
    exit(1)
}
print("item: \(service)")

var access: SecAccess?
let accStatus = SecKeychainItemCopyAccess(item as! SecKeychainItem, &access)
guard accStatus == errSecSuccess, let access else {
    print("ACL READ FAILED status=\(accStatus)")
    exit(1)
}

var aclList: CFArray?
let aclStatus = SecAccessCopyACLList(access, &aclList)
guard aclStatus == errSecSuccess, let acls = aclList as? [SecACL] else {
    print("ACL LIST FAILED status=\(aclStatus)")
    exit(1)
}

for (i, acl) in acls.enumerated() {
    var apps: CFArray?
    var desc: CFString?
    var prompt = SecKeychainPromptSelector()
    guard SecACLCopyContents(acl, &apps, &desc, &prompt) == errSecSuccess else { continue }
    let label = (desc as String?) ?? "?"

    let auths = (SecACLCopyAuthorizations(acl) as? [String]) ?? []

    guard let appList = apps as? [SecTrustedApplication] else {
        // nil app list == "any application" (unrestricted for these ops)
        print("\nACL[\(i)] \"\(label)\" auths=\(auths) → ANY APPLICATION (unrestricted)")
        continue
    }
    print("\nACL[\(i)] \"\(label)\" auths=\(auths) trustedApps=\(appList.count)")
    for app in appList {
        var data: CFData?
        guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess,
              let d = data as Data? else { print("   - <unreadable>"); continue }
        // The blob holds the path as embedded text; pull the printable run.
        let printable = String(decoding: d.filter { $0 >= 0x20 && $0 < 0x7f }, as: UTF8.self)
        if let r = printable.range(of: "/[^\u{0}]*", options: .regularExpression) {
            print("   - \(printable[r])")
        } else {
            print("   - <\(d.count) bytes, no path>")
        }
    }
}

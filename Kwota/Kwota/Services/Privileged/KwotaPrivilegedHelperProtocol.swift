//
//  KwotaPrivilegedHelperProtocol.swift
//  Kwota
//
//  XPC contract between the Kwota app and KwotaPrivilegedHelper, plus the
//  constants both sides must agree on. Compiled into BOTH targets.
//  `@objc` because NSXPC requires it.
//

import Foundation
import Security

@objc protocol KwotaPrivilegedHelperProtocol {
    /// Returns the helper's build version so the app can detect a stale
    /// helper left behind by an older app version.
    func helperVersion(reply: @escaping (String) -> Void)

    /// Permanently delete the contents of every system cache named by
    /// `identifiers`. Identifiers not in `SystemCacheCatalog` are ignored.
    /// Reply: (items removed, bytes freed, first error message or nil).
    func cleanSystemCaches(
        identifiers: [String],
        reply: @escaping (Int, Int64, String?) -> Void
    )

    /// Report the recursive byte size of every system cache named by
    /// `identifiers` (catalog identifiers only; unknown ones omitted). Lets the
    /// app show a real size for a directory it can't read unprivileged.
    func systemCacheSizes(
        identifiers: [String],
        reply: @escaping ([String: Int64]) -> Void
    )
}

/// Constants shared by the app and the helper. The Mach service name, the
/// helper bundle identifier, and the launchd plist `Label` are all the same
/// string by design.
enum KwotaHelperInfo {
    /// Bump whenever the helper's behavior changes. The app compares this
    /// against the running helper's `helperVersion` reply.
    static let version = "2"

    /// launchd Mach service name + helper bundle identifier.
    static let machServiceName = "com.thanhhaudev.Kwota.PrivilegedHelper"

    /// The launchd plist filename embedded in Contents/Library/LaunchDaemons.
    static let daemonPlistName = "com.thanhhaudev.Kwota.PrivilegedHelper.plist"

    /// The helper's *code-signing* identifier — NOT the same as
    /// `machServiceName`. A command-line tool (no bundle/Info.plist) signs
    /// with its PRODUCT_NAME, so the embedded signature's identifier is the
    /// bare `KwotaPrivilegedHelper`. The XPC code requirement the app applies
    /// to the helper connection MUST match this exact string, or the app
    /// rejects the real helper and every call fails with "couldn't
    /// communicate with a helper application".
    static let helperCodeSignIdentifier = "KwotaPrivilegedHelper"

    /// The team identifier of the *currently running* binary, resolved at
    /// runtime so any build-from-source signer's app + helper trust each
    /// other (both are signed by the same team). Returns nil for an
    /// unsigned/ad-hoc build. Callers must handle nil per side: the helper
    /// refuses the connection outright (fail-closed), while the app logs and
    /// proceeds without setting a code-signing requirement — so for unsigned
    /// builds the helper's own guard is the last line of defense, not the app's.
    static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Requirement the helper applies to incoming connections: only the real
    /// Kwota app, signed by `team`, may call the helper.
    static func appCodeRequirement(team: String) -> String {
        "anchor apple generic and identifier \"com.thanhhaudev.Kwota\""
        + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Requirement the app applies to the helper connection: only our real
    /// helper, signed by `team`, may answer. Pins the helper's code-signing
    /// identifier (`helperCodeSignIdentifier`), which is the tool's product
    /// name — not `machServiceName`.
    static func helperCodeRequirement(team: String) -> String {
        "anchor apple generic and identifier \"\(helperCodeSignIdentifier)\""
        + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The XPC interface with the `systemCacheSizes` reply dictionary's
    /// container + value classes explicitly whitelisted. NSXPC refuses to
    /// decode a reply *collection* whose classes aren't declared (unlike a
    /// plain `String` reply, which needs nothing), so without this the size
    /// call fails into its error handler and the app sees an empty result.
    /// Used by BOTH the app (remote interface) and the helper (exported
    /// interface) so the contract is identical on each end.
    static func makeXPCInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: KwotaPrivilegedHelperProtocol.self)
        let allowed = NSSet(array: [NSDictionary.self, NSString.self, NSNumber.self])
            as! Set<AnyHashable>
        interface.setClasses(
            allowed,
            for: #selector(KwotaPrivilegedHelperProtocol.systemCacheSizes(identifiers:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        return interface
    }
}

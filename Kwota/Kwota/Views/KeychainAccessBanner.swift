//
//  KeychainAccessBanner.swift
//  Kwota
//
//  Shown when a background credential read was refused because it would have
//  needed a consent dialog. Kwota never raises that dialog on its own — an
//  unanswered one froze the app for two hours on 2026-08-04 — so the user
//  asks for it explicitly, while they are at the machine to answer.
//
//  The detail text names "Always Allow" deliberately. That choice is what
//  makes the grant permanent: it writes a `teamid:` entry into the CLI item's
//  keychain partition list, which is the gate on this read (measured
//  2026-08-07 — see F-005). Plain "Allow" decrypts once and persists nothing,
//  so the banner comes back at the next token rotation and the button reads as
//  a treadmill. The two sit adjacent in the same dialog and "Always Allow" is
//  the highlighted default, so a user who reads nothing lands correctly — but
//  one who deliberately picks the more conservative-looking option gets the
//  worse outcome, which is exactly backwards without this sentence.
//

import SwiftUI

struct KeychainAccessBanner: View {
    let onGrant: () -> Void
    /// True while a Grant attempt is in flight (mirrors
    /// `RateLimitBanner.isProbing`). The underlying probe can wait up to two
    /// minutes on a real consent dialog, so this disables the button and
    /// shows a spinner instead of allowing a second tap to queue another
    /// up-to-120s probe behind the first.
    var isBusy: Bool = false

    var body: some View {
        KwotaInlineAlert(
            tint: .blue,
            icon: "key.fill",
            title: "Keychain access needed",
            detail: "Kwota needs your approval to read the Claude Code credential. Choose \"Always Allow\" — plain \"Allow\" lasts a single read, and the prompt returns at the next token rotation. Showing the last known figures until then.",
            actionTitle: "Grant",
            onAction: onGrant,
            isActionBusy: isBusy
        )
    }
}

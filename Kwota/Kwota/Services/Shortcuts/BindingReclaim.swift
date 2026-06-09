//
//  BindingReclaim.swift
//  Kwota
//

import Foundation

/// Pure reconciliation step for the Shortcuts ▸ Switch Account card.
///
/// When a previously-offline account `B` returns live with a stored hotkey
/// definition, any *other live* account that currently has the same
/// definition bound is silently displaced — its binding is cleared so that
/// the key fires for `B` (the original owner). The card then surfaces a
/// per-row error on the displaced row so the user can re-bind a new key.
///
/// Extracted as a pure function purely so it stays unit-testable without a
/// real `HotKeyStore` or `MenuBarViewModel`.
enum BindingReclaim {
    /// Returns the profile IDs whose stored binding equals the returner's
    /// stored binding (excluding the returner itself). Caller decides what
    /// to do with the list (typically: clear those bindings + show a row
    /// error). Returns an empty array when the returner has no stored
    /// binding or no other profile collides.
    static func displacedByReturner(
        returnerID: UUID,
        bindings: [UUID: HotKeyDefinition]
    ) -> [UUID] {
        guard let returnerBinding = bindings[returnerID] else { return [] }
        return bindings.compactMap { (id, def) in
            (id != returnerID && def == returnerBinding) ? id : nil
        }
    }
}

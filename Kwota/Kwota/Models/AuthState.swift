//
//  AuthState.swift
//  Kwota
//

import Foundation

enum AuthState: Equatable {
    case unauthenticated
    case refreshing
    case authenticated
    case expired
    /// The keychain needs the user's approval before Kwota can read the
    /// credential. Distinct from `.expired`: nothing is wrong with the
    /// account, and the previous figures stay on screen.
    case keychainAccessNeeded
    case error(String)
}

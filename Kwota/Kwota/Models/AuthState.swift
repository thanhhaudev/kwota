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
    case error(String)
}

//
//  IntExtensions.swift
//  Kwota
//

import Foundation

extension Int {
    /// Returns `self` if non-zero, otherwise `fallback`. Designed for
    /// reading values from `UserDefaults.integer(forKey:)`, which returns
    /// `0` when the key is absent — distinct from a deliberate `0`.
    func nonZeroOr(_ fallback: Int) -> Int {
        self == 0 ? fallback : self
    }
}

//
//  CaffeinateOptions.swift
//  Kwota
//

import Foundation

struct CaffeinateOptions: Equatable {
    var preventDisplaySleep: Bool
    var preventIdleSleep: Bool
    var preventSystemSleep: Bool
    var declareUserActivity: Bool
    var timeoutSeconds: Int?

    init(
        preventDisplaySleep: Bool = true,
        preventIdleSleep: Bool = true,
        preventSystemSleep: Bool = true,
        declareUserActivity: Bool = true,
        timeoutSeconds: Int? = nil
    ) {
        self.preventDisplaySleep = preventDisplaySleep
        self.preventIdleSleep = preventIdleSleep
        self.preventSystemSleep = preventSystemSleep
        self.declareUserActivity = declareUserActivity
        self.timeoutSeconds = timeoutSeconds
    }

    static let `default` = CaffeinateOptions()

    /// True if at least one assertion would be acquired when enabled.
    /// Intentionally excludes `timeoutSeconds`: a timeout-only config (all
    /// bool flags false, non-nil timeout) acquires no assertions and arms a
    /// no-op timer — not useful as a UI gate. Old `caffeinate`-CLI versions
    /// of this property returned true for timeout-only; that behavior is gone
    /// because it never produced a real awake session in the new IOKit path.
    var hasAnyFlag: Bool {
        preventDisplaySleep || preventIdleSleep || preventSystemSleep || declareUserActivity
    }
}

extension CaffeinateOptions: Codable {
    enum CodingKeys: String, CodingKey {
        case preventDisplaySleep, preventIdleSleep,
             preventSystemSleep, declareUserActivity, timeoutSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaffeinateOptions.default
        self.init(
            preventDisplaySleep: (try? c.decode(Bool.self, forKey: .preventDisplaySleep)) ?? d.preventDisplaySleep,
            preventIdleSleep:    (try? c.decode(Bool.self, forKey: .preventIdleSleep))    ?? d.preventIdleSleep,
            preventSystemSleep:  (try? c.decode(Bool.self, forKey: .preventSystemSleep))  ?? d.preventSystemSleep,
            declareUserActivity: (try? c.decode(Bool.self, forKey: .declareUserActivity)) ?? d.declareUserActivity,
            timeoutSeconds:      try? c.decode(Int.self, forKey: .timeoutSeconds)
        )
    }
}

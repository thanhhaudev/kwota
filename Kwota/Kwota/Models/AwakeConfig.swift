//
//  AwakeConfig.swift
//  Kwota
//

import Foundation

enum IdleWindow: String, CaseIterable, Codable, Identifiable {
    case m1, m2, m5, m10, m15
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .m1:  return 60
        case .m2:  return 120
        case .m5:  return 300
        case .m10: return 600
        case .m15: return 900
        }
    }
    var label: String {
        switch self {
        case .m1:  return "1 min"
        case .m2:  return "2 min"
        case .m5:  return "5 min"
        case .m10: return "10 min"
        case .m15: return "15 min"
        }
    }
}

/// How long the user must be away (no keyboard / mouse / trackpad input)
/// before auto mode is allowed to raise the assertion. While the user is
/// actively at the Mac, macOS can't idle-sleep anyway, so caffeinating is
/// pointless — the gate keeps the awake tint meaning "Kwota actually had
/// to keep the Mac awake". `.off` restores the ungated behavior.
enum UserIdleGate: String, CaseIterable, Codable, Identifiable {
    case off, s30, m1, m2
    var id: String { rawValue }
    var seconds: TimeInterval? {
        switch self {
        case .off: return nil
        case .s30: return 30
        case .m1:  return 60
        case .m2:  return 120
        }
    }
    var label: String {
        switch self {
        case .off: return "Off"
        case .s30: return "30 s"
        case .m1:  return "1 min"
        case .m2:  return "2 min"
        }
    }
}

enum BatteryThreshold: String, CaseIterable, Codable, Identifiable {
    case off, p10, p15, p20, p25, p30
    var id: String { rawValue }
    var percent: Int? {
        switch self {
        case .off: return nil
        case .p10: return 10
        case .p15: return 15
        case .p20: return 20
        case .p25: return 25
        case .p30: return 30
        }
    }
    var label: String {
        switch self {
        case .off: return "Off"
        case .p10: return "10 %"
        case .p15: return "15 %"
        case .p20: return "20 %"
        case .p25: return "25 %"
        case .p30: return "30 %"
        }
    }
}

enum TimeoutChoice: String, CaseIterable, Codable, Identifiable {
    case forever, m30, h1, h2, h4, h8
    var id: String { rawValue }
    var label: String {
        switch self {
        case .forever: return "Never"
        case .m30: return "30 min"
        case .h1:  return "1 h"
        case .h2:  return "2 h"
        case .h4:  return "4 h"
        case .h8:  return "8 h"
        }
    }
    var seconds: Int? {
        switch self {
        case .forever: return nil
        case .m30: return 30 * 60
        case .h1:  return 1 * 3600
        case .h2:  return 2 * 3600
        case .h4:  return 4 * 3600
        case .h8:  return 8 * 3600
        }
    }
}

struct AwakeConfig: Codable, Equatable {
    var autoEnabled: Bool
    var flags: CaffeinateOptions
    var idleWindow: IdleWindow
    var batteryThreshold: BatteryThreshold
    var forceTimeout: TimeoutChoice
    var userIdleGate: UserIdleGate

    static let `default` = AwakeConfig(
        autoEnabled: true,
        flags: CaffeinateOptions(
            preventDisplaySleep: false,
            preventIdleSleep: true,
            preventSystemSleep: false,
            declareUserActivity: false
        ),
        idleWindow: .m5,
        batteryThreshold: .p20,
        forceTimeout: .h2,
        userIdleGate: .m1
    )

    init(
        autoEnabled: Bool,
        flags: CaffeinateOptions,
        idleWindow: IdleWindow,
        batteryThreshold: BatteryThreshold,
        forceTimeout: TimeoutChoice,
        userIdleGate: UserIdleGate = .m1
    ) {
        self.autoEnabled = autoEnabled
        self.flags = flags
        self.idleWindow = idleWindow
        self.batteryThreshold = batteryThreshold
        self.forceTimeout = forceTimeout
        self.userIdleGate = userIdleGate
    }

    /// Decode missing fields to their default values, gracefully fall back
    /// on unknown enum cases, AND migrate old payloads that used the split
    /// `autoFlags`/`forceFlags` keys. Migration rule: prefer `autoFlags`
    /// (auto has been the dominant mode for the app's lifetime); fall back
    /// to `forceFlags`; finally default. The synthesized encoder only emits
    /// the current `CodingKeys` — legacy keys are not re-written.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AwakeConfig.default
        self.autoEnabled      = (try? c.decode(Bool.self,             forKey: .autoEnabled))      ?? d.autoEnabled
        self.idleWindow       = (try? c.decode(IdleWindow.self,        forKey: .idleWindow))       ?? d.idleWindow
        self.batteryThreshold = (try? c.decode(BatteryThreshold.self,  forKey: .batteryThreshold)) ?? d.batteryThreshold
        self.forceTimeout     = (try? c.decode(TimeoutChoice.self,     forKey: .forceTimeout))     ?? d.forceTimeout
        self.userIdleGate     = (try? c.decode(UserIdleGate.self,      forKey: .userIdleGate))     ?? d.userIdleGate
        self.flags            = Self.resolveFlags(decoder: decoder, container: c, default: d.flags)
    }

    /// Resolve flags from the current `flags` key, falling back to legacy
    /// `autoFlags`/`forceFlags` keys for older persisted payloads.
    /// Lives outside `init(from:)` so the legacy CodingKeys enum can stay
    /// scoped and so the synthesized `Encodable` stays clean (it only sees
    /// `CodingKeys` and so only emits current keys).
    private static func resolveFlags(
        decoder: Decoder,
        container: KeyedDecodingContainer<CodingKeys>,
        default fallback: CaffeinateOptions
    ) -> CaffeinateOptions {
        if let v = try? container.decode(CaffeinateOptions.self, forKey: .flags) { return v }
        guard let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self) else {
            return fallback
        }
        if let v = try? legacy.decode(CaffeinateOptions.self, forKey: .autoFlags) { return v }
        if let v = try? legacy.decode(CaffeinateOptions.self, forKey: .forceFlags) { return v }
        return fallback
    }

    private enum CodingKeys: String, CodingKey {
        case autoEnabled, flags, idleWindow, batteryThreshold, forceTimeout, userIdleGate
    }

    /// Decode-only keys for one-shot migration from the old `autoFlags`/
    /// `forceFlags` split. Kept out of `CodingKeys` so the synthesized
    /// `encode(to:)` doesn't try to emit nonexistent properties.
    private enum LegacyCodingKeys: String, CodingKey {
        case autoFlags, forceFlags
    }
}

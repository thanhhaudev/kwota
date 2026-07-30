//
//  PowerSourceSampler.swift
//  Kwota
//
//  Nonisolated read of the IOKit power-source registry. Extracted from
//  `IOPowerSourcesBatteryMonitor` so `AwakeWatchdog` can sample the battery
//  from its own queue — the monitor's copy was `private static` on a
//  `@MainActor` type and therefore unreachable from off-main code.
//
//  Call-rate note: this used to run a handful of times a day (once per IOKit
//  notification). The watchdog calls it twice a minute while caffeinated,
//  ~960 times across an eight-hour session, so the CoreFoundation ownership
//  rules below stop being incidental. `IOPSCopyPowerSourcesInfo` and
//  `IOPSCopyPowerSourcesList` are *Copy* functions returning +1 and must use
//  `takeRetainedValue`; `IOPSGetPowerSourceDescription` is a *Get* returning
//  +0 and must use `takeUnretainedValue`. Getting this wrong now leaks one CF
//  blob per call instead of being invisible.
//

import Foundation
import IOKit.ps

nonisolated enum PowerSourceSampler {
    static func snapshot() -> BatteryReading {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]

        // Walk the list once; pick the first battery source that yields a
        // capacity reading. Desktops produce an empty list and fall through
        // to the nil-percent reading.
        for ps in list {
            guard let dict = IOPSGetPowerSourceDescription(blob, ps).takeUnretainedValue()
                    as? [String: Any] else { continue }
            let state = dict[kIOPSPowerSourceStateKey] as? String
            let current = dict[kIOPSCurrentCapacityKey] as? Int
            let max = dict[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = current.map { max == 0 ? 0 : Int((Double($0) / Double(max)) * 100) }
            let isBattery = state == kIOPSBatteryPowerValue
            return BatteryReading(isOnBattery: isBattery, percent: percent)
        }
        return BatteryReading(isOnBattery: false, percent: nil)
    }
}

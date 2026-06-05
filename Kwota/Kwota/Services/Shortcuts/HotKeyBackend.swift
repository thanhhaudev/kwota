//
//  HotKeyBackend.swift
//  Kwota
//

import AppKit
import Carbon.HIToolbox

/// Indirection over the real Carbon HotKey API. Exists so `HotKeyManager`
/// can be tested with a fake without touching the OS-level hotkey table.
@MainActor
protocol HotKeyBackend: AnyObject {
    /// Returns true if the OS accepted the registration.
    func register(definition: HotKeyDefinition, id: UInt32, action: @escaping () -> Void) -> Bool
    func unregister(id: UInt32)
}

/// C-style callback for Carbon's `InstallEventHandler`. Cannot capture
/// Swift state, so the per-backend instance is round-tripped through the
/// opaque `userData` pointer set up at install time.
private let hotKeyEventCallback: EventHandlerUPP = { _, eventRef, ctx in
    guard let eventRef, let ctx else { return noErr }
    var hkid = EventHotKeyID()
    let getStatus = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hkid
    )
    guard getStatus == noErr else { return noErr }
    let backend = Unmanaged<CarbonHotKeyBackend>.fromOpaque(ctx).takeUnretainedValue()
    // Carbon delivers app-target events on the main thread, but hop
    // explicitly to satisfy `@MainActor` isolation on the action.
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            backend.fire(id: hkid.id)
        }
    }
    return noErr
}

/// Real backend backed by Carbon `RegisterEventHotKey`. Installs one
/// application-level event handler at init; routes `kEventHotKeyPressed`
/// events to the per-id action stored in `actions`.
@MainActor
final class CarbonHotKeyBackend: HotKeyBackend {
    /// 4-char OSType ("KWOT") namespacing our hotkey IDs.
    private static let signature: OSType = OSType(0x4B574F54)

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    init() {
        installEventHandler()
    }

    deinit {
        for ref in refs.values {
            UnregisterEventHotKey(ref)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register(definition: HotKeyDefinition, id: UInt32, action: @escaping () -> Void) -> Bool {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let modifiers = Self.carbonModifiers(from: definition.nsModifiers)
        let status = RegisterEventHotKey(
            UInt32(definition.keyCode),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            AppLog.shared.log("CarbonHotKeyBackend: RegisterEventHotKey failed (status=\(status))", level: .error)
            return false
        }
        refs[id] = ref
        actions[id] = action
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        actions.removeValue(forKey: id)
    }

    /// Invoked from the Carbon event callback after it hops to the main
    /// actor. Looks up and fires the action bound to `id`.
    func fire(id: UInt32) {
        actions[id]?()
    }

    // MARK: - Internals

    private func installEventHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventCallback,
            1,
            &spec,
            context,
            &eventHandler
        )
    }

    private static func carbonModifiers(from ns: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if ns.contains(.command) { mods |= UInt32(cmdKey) }
        if ns.contains(.option)  { mods |= UInt32(optionKey) }
        if ns.contains(.shift)   { mods |= UInt32(shiftKey) }
        if ns.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }
}

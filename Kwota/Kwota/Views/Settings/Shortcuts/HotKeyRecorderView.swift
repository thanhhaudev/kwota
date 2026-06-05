//
//  HotKeyRecorderView.swift
//  Kwota
//

import SwiftUI
import AppKit
import Carbon.HIToolbox

/// macOS System Settings → Keyboard-style recorder.
///
/// Idle: right-aligned glyph string (or "none"). Hover reveals an × to clear.
/// Double-click (or Return/Space when focused) starts recording. While
/// recording, the combo area gets an accent-tinted pill, ESC reverts to the
/// previous value, and a click outside the recorder cancels.
struct HotKeyRecorderView: View {
    @Binding var definition: HotKeyDefinition?
    var onChange: (() -> Void)? = nil

    @State private var isRecording = false
    @State private var isHovering = false
    @State private var previousDefinition: HotKeyDefinition?
    @State private var keyMonitor: Any?
    @State private var mouseMonitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            if isHovering && !isRecording && definition != nil {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear shortcut")
            }

            recorderContent
        }
        .frame(minWidth: 120, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .gesture(TapGesture(count: 2).onEnded { startRecording() })
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) { startRecording(); return .handled }
        .onKeyPress(.space)  { startRecording(); return .handled }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .onDisappear { removeMonitors() }
    }

    private var state: RecorderVisualState {
        .resolve(definition: definition, isRecording: isRecording)
    }

    private var textColor: Color {
        if definition == nil { return .secondary }
        return .primary
    }

    @ViewBuilder
    private var recorderContent: some View {
        if isRecording {
            BlinkingCaret()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        } else {
            Text(state.displayString)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(textColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        }
    }

    private var accessibilityLabel: String {
        if let definition {
            return "Shortcut: \(HotKeyFormatter.string(for: definition)). Double-click to edit."
        }
        return "Shortcut: none. Double-click to record."
    }

    // MARK: - Recording lifecycle

    private func startRecording() {
        guard !isRecording else { return }
        previousDefinition = definition
        isRecording = true
        installMonitors()
    }

    private func cancelRecording() {
        isRecording = false
        removeMonitors()
        // Revert silently — no onChange. ESC/outside-click must not look
        // like a user-driven binding change to the parent card.
        if definition != previousDefinition {
            definition = previousDefinition
        }
    }

    private func commitRecording(_ captured: HotKeyDefinition) {
        isRecording = false
        removeMonitors()
        definition = captured
        onChange?()
    }

    private func clear() {
        definition = nil
        onChange?()
    }

    // MARK: - Event monitors

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event)
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            handleMouse(event)
        }
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

        // Bare ESC reverts to the pre-recording value.
        if Int(event.keyCode) == kVK_Escape && mods.isEmpty {
            cancelRecording()
            return nil
        }

        let captured = HotKeyDefinition(
            keyCode: event.keyCode,
            rawModifiers: event.modifierFlags.rawValue
        )
        commitRecording(captured)
        return nil
    }

    private func handleMouse(_ event: NSEvent) -> NSEvent? {
        // Click outside the recorder cancels. Hover state is used as a
        // proxy for hit-test; a fast click immediately after the pointer
        // leaves can race the SwiftUI tracking-area update and miss the
        // cancel. The user recovers with ESC or the × button.
        if !isHovering {
            cancelRecording()
        }
        return event
    }
}

// MARK: - Blinking text caret used while recording

private struct BlinkingCaret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let slot = Int(context.date.timeIntervalSinceReferenceDate * 2)
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 1.5, height: 14)
                .opacity(slot.isMultiple(of: 2) ? 1 : 0)
        }
    }
}

// MARK: - Pure visual-state helper

enum RecorderVisualState: Equatable {
    case unset
    case set(HotKeyDefinition)
    case recording

    static func resolve(definition: HotKeyDefinition?, isRecording: Bool) -> RecorderVisualState {
        if isRecording { return .recording }
        if let definition { return .set(definition) }
        return .unset
    }

    var displayString: String {
        switch self {
        case .unset: return "none"
        case .recording: return "Type shortcut…"
        case .set(let def): return HotKeyFormatter.string(for: def)
        }
    }
}

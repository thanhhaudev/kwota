//
//  MenuBarIconRenderer.swift
//  Kwota
//

import SwiftUI
import AppKit

/// Renders `MenuBarPillBase` to an `NSImage` so the menu-bar slot has a
/// view with a guaranteed intrinsic size. Placing the SwiftUI view directly
/// in `MenuBarExtra(label:)` failed because `Path` and `Capsule().fill()`
/// have zero intrinsic content size, and `NSStatusItem` ended up allocating
/// a 0pt-wide slot. Going through `Image(nsImage:)` sidesteps that.
@MainActor
enum MenuBarIconRenderer {
    /// Returns a fresh `NSImage` for the given inputs. Pure: same inputs →
    /// same output. `nil` is reserved for `ImageRenderer` failures (extreme
    /// — typically out of memory). Callers should fall back to a SF symbol.
    static func image(
        style: MenuBarStyle,
        reading: MenuBarReading,
        colorScheme: ColorScheme,
        displayScale: CGFloat
    ) -> NSImage? {
        let content = makeContent(style: style, reading: reading)
            .environment(\.colorScheme, colorScheme)

        let renderer = ImageRenderer(content: content)
        renderer.scale = displayScale
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false   // preserve tint accents on variants 2–4
        return image
    }

    @ViewBuilder
    static func makeContent(
        style: MenuBarStyle,
        reading: MenuBarReading
    ) -> some View {
        switch style {
        case .original:
            MenuBarPillBase(
                foreground: .primary,
                fillFraction: nil,
                fillTint: .clear
            ) {
                BarsTail(foreground: .primary)
            }
        case .fillBackground:
            MenuBarPillBase(
                foreground: .primary,
                fillFraction: MenuBarUsageDriver.remainingFraction(for: reading.utilization),
                fillTint: reading.tint
            ) {
                BarsTail(foreground: .primary)
            }
        case .percentText:
            MenuBarPillBase(
                foreground: .primary,
                fillFraction: nil,
                fillTint: .clear
            ) {
                PercentTextTail(reading: reading)
            }
        case .percentRing:
            MenuBarPillBase(
                foreground: .primary,
                fillFraction: nil,
                fillTint: .clear
            ) {
                PercentRingTail(reading: reading)
            }
        case .tintDot:
            TintDotIcon(tint: reading.tint)
        }
    }
}

/// Standalone circular indicator for `.tintDot`. 14×14pt, 1pt primary
/// border, interior fill uses the same usage-level tint as `.fillBackground`
/// (green/yellow/red by utilization, gray when nil). No "K" glyph, no pill —
/// reads like a native macOS status indicator (Bluetooth/wifi style).
private struct TintDotIcon: View {
    let tint: Color

    var body: some View {
        Circle()
            .fill(tint.gradient)
            .overlay(Circle().strokeBorder(Color.primary, lineWidth: 1))
            .frame(width: 14, height: 14)
    }
}

// MARK: - Tail views (shared with MenuBarStylePreviewTile)

/// 3 ascending capsule bars used by `.original` and `.fillBackground`.
/// Bottom-aligned in an 8pt-tall row; total width ~8pt.
struct BarsTail: View {
    let foreground: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            Capsule().fill(foreground).frame(width: 2, height: 2)
            Capsule().fill(foreground).frame(width: 2, height: 5)
            Capsule().fill(foreground).frame(width: 2, height: 8)
        }
        .frame(height: 8, alignment: .bottom)
    }
}

/// Mono-spaced percent string for `.percentText`. Represents headroom:
/// shows 100% at 0% utilization and drains to 0% at full, matching the
/// `.percentRing` and `.fillBackground` variants. The tail auto-sizes
/// to hug the digits so K and the percent share the same tight spacing
/// as the ring variant; the pill width drifts a few points as digits
/// change (e.g. "5%" → "100%"), which matches macOS menu-bar items like
/// battery or wifi. Color matches the K glyph (`.primary`) so the
/// percent reads as part of the same monochrome label and adapts with
/// the menu-bar appearance; nil utilization shows "—" at the same
/// primary weight.
struct PercentTextTail: View {
    let reading: MenuBarReading

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(height: 8)
            .fixedSize()
    }

    private var label: String {
        guard let u = reading.utilization else { return "—" }
        let remaining = max(0, min(100, 100 - u))
        return "\(Int(remaining.rounded()))%"
    }
}

/// Small circular progress ring for `.percentRing`. 8×8pt, stroke 1.5pt,
/// rotated -90° so the arc starts at 12 o'clock and sweeps clockwise.
/// Represents headroom: starts full at 0% utilization and drains to empty
/// at 100%, matching the fill-background variant's semantics. nil
/// utilization shows just the background circle.
struct PercentRingTail: View {
    let reading: MenuBarReading

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(reading.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 8, height: 8)
    }

    private var fraction: CGFloat {
        MenuBarUsageDriver.remainingFraction(for: reading.utilization)
    }
}

//
//  MenuBarPillBase.swift
//  Kwota
//

import SwiftUI

/// Shared "rounded-rect outline + K + tail slot" container used by every
/// menu-bar display variant. The pill auto-sizes to fit the HStack content;
/// height is fixed at 18pt to fit a standard menu-bar item. Corner radius
/// matches the macOS input-source / locale icons (~22% of height).
///
/// `fillFraction` is non-nil only for the fill-background variant. When set,
/// a tinted rectangle grows from the leading edge proportional to the
/// fraction; the outer `clipShape` rounds the visible corners so the fill
/// hugs the pill shape.
struct MenuBarPillBase<Tail: View>: View {
    let foreground: Color
    let fillFraction: CGFloat?
    let fillTint: Color
    @ViewBuilder var tail: () -> Tail

    private static var pillShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            KGlyph(foreground: foreground)
            tail()
        }
        .padding(.horizontal, 5)
        .frame(height: 16)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            ZStack {
                if let fraction = fillFraction {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(fillTint.gradient)
                            .frame(width: proxy.size.width * max(0, min(1, fraction)))
                    }
                }
                Self.pillShape
                    .stroke(foreground, lineWidth: 2)
            }
        )
        .clipShape(Self.pillShape)
    }
}

/// Typographic "K" rendered with the system bold font so it matches the
/// macOS input-source / locale icons. Frame height stays at 10pt to share
/// a baseline with the other tails.
private struct KGlyph: View {
    let foreground: Color

    var body: some View {
        Text("K")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(height: 8)
            .fixedSize()
    }
}

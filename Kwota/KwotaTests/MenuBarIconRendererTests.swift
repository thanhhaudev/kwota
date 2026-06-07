//
//  MenuBarIconRendererTests.swift
//  KwotaTests
//

import XCTest
import SwiftUI
@testable import Kwota

@MainActor
final class MenuBarIconRendererTests: XCTestCase {

    private func reading(_ utilization: Double?) -> MenuBarReading {
        MenuBarReading(utilization: utilization, tint: UsageLevel.tint(for: utilization))
    }

    func test_image_returnsNonNilForAllStylesAndReadings() {
        let styles: [MenuBarStyle] = [.original, .fillBackground, .percentText, .percentRing, .tintDot]
        let utilizations: [Double?] = [nil, 0, 50, 100]
        let schemes: [ColorScheme] = [.dark, .light]

        for style in styles {
            for u in utilizations {
                for scheme in schemes {
                    let img = MenuBarIconRenderer.image(
                        style: style,
                        reading: reading(u),
                        colorScheme: scheme,
                        displayScale: 2
                    )
                    XCTAssertNotNil(img, "nil image for style=\(style) u=\(String(describing: u)) scheme=\(scheme)")
                    if let img {
                        XCTAssertGreaterThan(img.size.width, 0,
                            "zero width for style=\(style) u=\(String(describing: u)) scheme=\(scheme)")
                        XCTAssertGreaterThan(img.size.height, 0,
                            "zero height for style=\(style) u=\(String(describing: u)) scheme=\(scheme)")
                    }
                }
            }
        }
    }

    func test_image_isTemplateFalse_preservesTintColors() {
        let img = MenuBarIconRenderer.image(
            style: .percentText,
            reading: reading(50),
            colorScheme: .dark,
            displayScale: 2
        )
        XCTAssertNotNil(img)
        XCTAssertFalse(img?.isTemplate ?? true,
            "isTemplate must be false so green/yellow/red tints survive NSStatusItem rendering")
    }
}

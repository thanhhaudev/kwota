//
//  CacheEvaluationPromptsTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class CacheEvaluationPromptsTests: XCTestCase {
    /// Drift guard: the activity layer recognizes Kwota's own cache-eval runs by
    /// matching `activitySignature` against the transcript the provider CLI
    /// writes. That only works if the signature is a verbatim substring of the
    /// prompts actually sent. If someone rewrites the framing sentence and drops
    /// the fragment, this fails before the chart silently starts counting
    /// evaluations as user activity again.
    func test_activitySignature_isVerbatimSubstringOfBothSystemPrompts() {
        let sig = CacheEvaluationPrompts.activitySignature
        XCTAssertFalse(sig.isEmpty)
        for lang in CacheAILanguage.allCases {
            XCTAssertTrue(
                CacheEvaluationPrompts.systemSingle(language: lang).contains(sig),
                "systemSingle(\(lang)) must contain the activity signature verbatim")
            XCTAssertTrue(
                CacheEvaluationPrompts.systemBulk(language: lang).contains(sig),
                "systemBulk(\(lang)) must contain the activity signature verbatim")
        }
    }
}

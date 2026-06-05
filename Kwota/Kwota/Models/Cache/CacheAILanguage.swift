//
//  CacheAILanguage.swift
//  Kwota
//

import Foundation

/// Output language the AI evaluator should use when generating
/// `purpose`/`warning`/`detail` text. The Swift UI itself stays English —
/// this only affects the LLM-produced strings. Picker is small (5 entries)
/// because more options inflate Settings without much real benefit; add
/// more as user feedback comes in.
enum CacheAILanguage: String, Codable, Equatable, CaseIterable, Identifiable {
    case english   = "en"
    case vietnamese = "vi"
    case japanese  = "ja"
    case chineseSimplified = "zh-Hans"
    case korean    = "ko"

    var id: String { rawValue }

    /// Picker display label (English — matches the rest of Settings copy).
    var displayName: String {
        switch self {
        case .english:            return "English"
        case .vietnamese:         return "Vietnamese"
        case .japanese:           return "Japanese"
        case .chineseSimplified:  return "Chinese (Simplified)"
        case .korean:             return "Korean"
        }
    }

    /// Phrase injected into the system prompt as "Respond in {promptName}".
    /// Spelled out rather than using the locale code so the model doesn't
    /// have to interpret tags like `zh-Hans`.
    var promptName: String {
        switch self {
        case .english:            return "English"
        case .vietnamese:         return "Vietnamese"
        case .japanese:           return "Japanese"
        case .chineseSimplified:  return "Simplified Chinese"
        case .korean:             return "Korean"
        }
    }
}

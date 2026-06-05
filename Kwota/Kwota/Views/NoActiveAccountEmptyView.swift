//
//  NoActiveAccountEmptyView.swift
//  Kwota
//

import SwiftUI

/// Popover / settings empty state shown when no account is active
/// (`activeProfileId == nil`). Provider-agnostic: the guidance lists the
/// providers Kwota knows about, sourced from the registry. Auto-detect picks
/// up a running agent automatically — this view offers guidance, not a button.
struct NoActiveAccountEmptyView: View {
    let providerNames: [String]

    /// Joins provider display names in English list style:
    /// `[]` → "", `[a]` → "a", `[a,b]` → "a or b",
    /// `[a,b,c]` → "a, b, or c" (Oxford "or").
    static func joinedNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) or \(names[1])"
        default:
            let head = names.dropLast().joined(separator: ", ")
            return "\(head), or \(names.last!)"
        }
    }

    private var detail: String {
        let joined = Self.joinedNames(providerNames)
        if joined.isEmpty {
            return "Start a supported agent and Kwota will track usage automatically."
        }
        return "Start \(joined) and Kwota will track usage automatically."
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("No active account")
                    .font(.system(size: 15, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
    }
}

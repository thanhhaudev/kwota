//
//  TokenBreakdown.swift
//  Kwota
//

import Foundation

struct TokenBreakdown: Codable, Equatable {
    let input: Int
    let output: Int
    let cacheCreation: Int
    let cacheRead: Int

    init(input: Int = 0, output: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
    }

    var billable: Int { input + output }

    static let zero = TokenBreakdown()

    static func + (lhs: TokenBreakdown, rhs: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }

    private enum CodingKeys: String, CodingKey {
        case input = "input_tokens"
        case output = "output_tokens"
        case cacheCreation = "cache_creation_input_tokens"
        case cacheRead = "cache_read_input_tokens"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.input = (try? c.decode(Int.self, forKey: .input)) ?? 0
        self.output = (try? c.decode(Int.self, forKey: .output)) ?? 0
        self.cacheCreation = (try? c.decode(Int.self, forKey: .cacheCreation)) ?? 0
        self.cacheRead = (try? c.decode(Int.self, forKey: .cacheRead)) ?? 0
    }
}

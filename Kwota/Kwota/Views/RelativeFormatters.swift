//
//  RelativeFormatters.swift
//  Kwota
//

import Foundation

enum RelativeFormatters {
    /// Cached at module level — instantiating `RelativeDateTimeFormatter` per
    /// view-body evaluation is wasteful.
    static let full: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static let abbreviated: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

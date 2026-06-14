//  ProtobufScanner.swift
//  Kwota
//
//  Generic, allocation-light protobuf reader: pulls leaf varints and strings
//  at a known set of dotted field-paths (e.g. "1.4.2", "1.9.4.1"). Descends
//  into length-delimited submessages only along a prefix of a wanted path, so
//  it never walks subtrees it doesn't need. Every decode step is bounds-checked
//  (see `safeLength`) so a torn/short blob returns partial results, never traps.

import Foundation

enum ProtobufScanner {
    struct Result {
        var varints: [String: [UInt64]] = [:]
        var strings: [String: [String]] = [:]
    }

    /// Walk `data`, collecting varint and string leaves whose dotted path is in
    /// `wanted`. A length-delimited field is descended into when some wanted
    /// path has it as a strict prefix; otherwise, if the path itself is wanted,
    /// it's recorded as a UTF-8 string. `maxDepth` bounds recursion.
    static func scan(_ data: Data, wanted: Set<String>, maxDepth: Int = 8) -> Result {
        var result = Result()
        func walk(_ data: Data, _ prefix: String, _ depth: Int) {
            var cursor = data.startIndex
            while cursor < data.endIndex {
                guard let tag = readVarint(data, &cursor) else { return }
                let field = tag >> 3
                let wire = tag & 0x7
                let path = prefix.isEmpty ? "\(field)" : "\(prefix).\(field)"
                switch wire {
                case 0:
                    guard let v = readVarint(data, &cursor) else { return }
                    if wanted.contains(path) { result.varints[path, default: []].append(v) }
                case 2:
                    guard let len = readVarint(data, &cursor),
                          let n = safeLength(len, cursor: cursor, in: data) else { return }
                    let end = data.index(cursor, offsetBy: n)
                    let sub = Data(data[cursor..<end])   // re-base slice indices to 0
                    cursor = end
                    if depth < maxDepth, wanted.contains(where: { $0.hasPrefix(path + ".") }) {
                        walk(sub, path, depth + 1)
                    } else if wanted.contains(path), let s = String(data: sub, encoding: .utf8) {
                        result.strings[path, default: []].append(s)
                    }
                case 1:
                    guard let n = safeLength(8, cursor: cursor, in: data) else { return }
                    cursor = data.index(cursor, offsetBy: n)
                case 5:
                    guard let n = safeLength(4, cursor: cursor, in: data) else { return }
                    cursor = data.index(cursor, offsetBy: n)
                default:
                    if !skipField(data, &cursor, tag: tag) { return }
                }
            }
        }
        walk(data, "", 0)
        return result
    }

    // MARK: - Primitives (shared with AntigravityOverageReader)

    /// Read a base-128 varint at `cursor`, advancing it. nil on truncation;
    /// caps at 10 bytes (proto3 max).
    static func readVarint(_ data: Data, _ cursor: inout Data.Index) -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0, read = 0
        while cursor < data.endIndex {
            let byte = data[cursor]
            cursor = data.index(after: cursor)
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7; read += 1
            if read >= 10 { return nil }
        }
        return nil
    }

    /// Skip an unknown field by wire type (0 varint, 1 fixed64, 2 len-delim, 5 fixed32).
    static func skipField(_ data: Data, _ cursor: inout Data.Index, tag: UInt64) -> Bool {
        switch tag & 0x7 {
        case 0: return readVarint(data, &cursor) != nil
        case 1:
            guard let n = safeLength(8, cursor: cursor, in: data) else { return false }
            cursor = data.index(cursor, offsetBy: n); return true
        case 2:
            guard let len = readVarint(data, &cursor),
                  let n = safeLength(len, cursor: cursor, in: data) else { return false }
            cursor = data.index(cursor, offsetBy: n); return true
        case 5:
            guard let n = safeLength(4, cursor: cursor, in: data) else { return false }
            cursor = data.index(cursor, offsetBy: n); return true
        default: return false
        }
    }

    /// Convert a wire length to a safe in-bounds `Int`, or nil if it overruns
    /// the buffer or exceeds `Int.max` (so a torn blob can't trap on the cast).
    static func safeLength(_ len: UInt64, cursor: Data.Index, in data: Data) -> Int? {
        guard let n = Int(exactly: len) else { return nil }
        let remaining = data.distance(from: cursor, to: data.endIndex)
        guard n >= 0, n <= remaining else { return nil }
        return n
    }
}

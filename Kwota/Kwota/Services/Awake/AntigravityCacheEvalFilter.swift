//
//  AntigravityCacheEvalFilter.swift
//  Kwota
//

import Foundation

/// Tells Kwota's own cache-evaluation `agy -p` runs apart from the user's real
/// Antigravity activity.
///
/// The Cache → AI feature evaluates folders by spawning the Antigravity CLI,
/// which writes a session transcript to
/// `~/.gemini/antigravity-cli/brain/**/transcript.jsonl` — the exact tree the
/// Awake activity chart watches. Without this filter every cache evaluation
/// surfaces as a phantom Antigravity agent-reply on the chart, even on days the
/// user never opened Antigravity (they only had Kwota evaluate caches).
///
/// The discriminator is **content-based and stateless**: Kwota's eval prompt
/// (`CacheEvaluationPrompts`) carries a verbatim signature into the transcript's
/// first `USER_INPUT` line, and a real user session never does. Matching on
/// content rather than timing means a genuine Antigravity session running
/// *concurrently* with an evaluation is still counted — only the evaluation's
/// own session is excluded. The same check serves both the live FSEvents
/// watcher and the launch/backfill scanner, so a transcript is treated
/// identically however it's discovered.
enum AntigravityCacheEvalFilter {
    /// UTF-8 bytes of the cache-eval prompt signature. A real prompt would have
    /// to quote this fragment verbatim to be mistaken for an eval.
    private static let signatureData = Data(CacheEvaluationPrompts.activitySignature.utf8)

    /// True when `data` contains the cache-eval signature, i.e. the whole
    /// session is one of Kwota's own evaluations. Byte-substring scan, so it's
    /// independent of the transcript's JSON shape and needs no parse.
    static func isCacheEvalTranscript(_ data: Data) -> Bool {
        guard !signatureData.isEmpty else { return false }
        return data.range(of: signatureData) != nil
    }

    /// True when the transcript file at `path` is a cache-eval session. The
    /// signature sits at the very start of the first `USER_INPUT` line, so a
    /// bounded head read suffices — this avoids re-scanning large real-session
    /// transcripts (the IDE writes multi-MB files) on every append. A
    /// missing/unreadable file classifies as *not* an eval: we never suppress
    /// activity we can't positively attribute to Kwota.
    static func isCacheEvalTranscript(path: String, maxBytes: Int = 16_384) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        return isCacheEvalTranscript(data)
    }
}

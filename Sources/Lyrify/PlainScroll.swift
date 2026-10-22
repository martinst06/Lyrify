import Foundation

/// Pace math for auto-scrolling *unsynced* (plain-text) lyrics.
///
/// LRCLIB-plain and Genius lyrics carry no timestamps, so we can't highlight the true
/// current line. Instead we estimate: assume the words are spread evenly across the song
/// and map playback progress onto the line list. Rough by nature — intros, outros and
/// instrumental breaks throw it off — but enough to keep the block drifting with the music
/// instead of sitting still.
enum PlainScroll {
    /// Fraction of the track elapsed, clamped to `0...1`.
    /// A non-positive `durationMs` (not yet loaded / malformed) yields `0` rather than dividing by zero.
    static func progress(positionSec: Double, durationMs: Int) -> Double {
        guard durationMs > 0 else { return 0 }
        let fraction = positionSec / (Double(durationMs) / 1000)
        return min(max(fraction, 0), 1)
    }

    /// Line index to scroll to for a given `progress`, clamped to a valid index of a
    /// `lineCount`-length list. An empty list scrolls to `0`.
    static func targetLine(progress: Double, lineCount: Int) -> Int {
        guard lineCount > 1 else { return 0 }
        let clamped = min(max(progress, 0), 1)
        let index = (clamped * Double(lineCount - 1)).rounded()
        return min(max(Int(index), 0), lineCount - 1)
    }
}

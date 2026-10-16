import AVFoundation
import Foundation

/// Native video editing for the `trim_and_merge_videos` tool: cut each clip to a range and join them in
/// order with AVFoundation (no clicking, no extra apps). Pass-through export, so no re-encode when the
/// clips share a format.
enum Media {
    struct Clip { let url: URL; let start: Double?; let end: Double? }

    static func trimAndMerge(_ clips: [Clip], output: URL?) async throws -> (url: URL, seconds: Double) {
        guard !clips.isEmpty else { throw err("no clips") }
        let comp = AVMutableComposition()
        guard let video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw err("can't make a video track") }
        var audio: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        var transform: CGAffineTransform?
        for clip in clips {
            guard FileManager.default.fileExists(atPath: clip.url.path) else { throw err("not found: \(clip.url.lastPathComponent)") }
            let asset = AVURLAsset(url: clip.url)
            let duration = try await asset.load(.duration)
            let start = CMTime(seconds: max(0, clip.start ?? 0), preferredTimescale: 600)
            let end = clip.end.map { CMTimeMinimum(CMTime(seconds: $0, preferredTimescale: 600), duration) } ?? duration
            guard end > start else { throw err("empty range in \(clip.url.lastPathComponent)") }
            let range = CMTimeRange(start: start, end: end)
            guard let v = try await asset.loadTracks(withMediaType: .video).first else { throw err("no video in \(clip.url.lastPathComponent)") }
            try video.insertTimeRange(range, of: v, at: cursor)
            if transform == nil { transform = try await v.load(.preferredTransform) }
            if let a = try await asset.loadTracks(withMediaType: .audio).first {
                if audio == nil { audio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                try audio?.insertTimeRange(range, of: a, at: cursor)
            }
            cursor = cursor + range.duration
        }
        video.preferredTransform = transform ?? .identity

        let out = output ?? defaultOutput(next: clips[0].url)
        // Passthrough first (fast, lossless); re-encode only if the clips' formats don't mix.
        var lastError = "export failed"
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            try? FileManager.default.removeItem(at: out)
            guard let export = AVAssetExportSession(asset: comp, presetName: preset) else { continue }
            export.outputURL = out
            export.outputFileType = .mov
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
            if export.status == .completed { return (out, cursor.seconds) }
            lastError = export.error?.localizedDescription ?? lastError
            Log.error("video export (\(preset)) failed: \(lastError)")
        }
        throw err(lastError)
    }

    /// "Merged 2026-10-16 at 22.40.12.mov" next to the first clip.
    static func defaultOutput(next to: URL) -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return to.deletingLastPathComponent().appendingPathComponent("Merged \(f.string(from: Date())).mov")
    }

    /// "9:35", "09:35", "1:02:03", "575" → seconds.
    static func seconds(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let parts = s.split(separator: ":").map { Double($0) }
        guard !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    private static func err(_ m: String) -> NSError { NSError(domain: "media", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }
}

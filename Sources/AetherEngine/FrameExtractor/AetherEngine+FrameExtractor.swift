import Foundation

extension AetherEngine {
    /// Vends a `FrameExtractor` for the currently loaded URL and its
    /// HTTP headers, or nil if nothing is loaded.
    ///
    /// The engine does NOT retain the returned extractor; the caller
    /// owns its lifecycle. Call `await shutdown()` for prompt teardown
    /// of the decode context; merely releasing the reference is also
    /// safe but defers cleanup until the idle-close timer fires.
    /// Used for scrub-preview of the playing item.
    /// Recents-style callers that need frames from arbitrary items
    /// should construct `FrameExtractor(url:httpHeaders:)` directly.
    public func makeFrameExtractor() -> FrameExtractor? {
        guard let url = loadedURL else { return nil }
        return FrameExtractor(url: url, httpHeaders: loadedOptions.httpHeaders)
    }
}

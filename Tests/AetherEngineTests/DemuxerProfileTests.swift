import Testing
@testable import AetherEngine

struct DemuxerProfileTests {
    @Test("playback profile keeps the large probe budget + prefetch")
    func playbackDefaults() {
        let p = DemuxerOpenProfile.playback
        #expect(p.probesize == 50 * 1024 * 1024)
        #expect(p.maxAnalyzeDuration == 60 * 1_000_000)
        #expect(p.avioPrefetch == true)
        #expect(p.avioChunkSize == 4 * 1024 * 1024)
    }

    @Test("stillExtraction profile is random-access tuned")
    func stillExtractionTuned() {
        let p = DemuxerOpenProfile.stillExtraction
        #expect(p.avioPrefetch == false)
        #expect(p.avioChunkSize < DemuxerOpenProfile.playback.avioChunkSize)
        #expect(p.probesize < DemuxerOpenProfile.playback.probesize)
        #expect(p.maxAnalyzeDuration < DemuxerOpenProfile.playback.maxAnalyzeDuration)
    }
}

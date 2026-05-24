import Foundation

/// Snapshot of live playback telemetry, emitted by `LiveTelemetrySampler`
/// at 1 Hz while the engine is `.playing` or `.paused`. Optionals encode
/// path-asymmetry: a `nil` value means the field is not available on the
/// current backend (e.g. `droppedFrameCount` is `nil` on the software
/// path because dav1d does not silently drop frames, and `avSyncGapMs`
/// is `nil` on the native path because AVPlayer owns sync internally).
public struct LiveTelemetry: Equatable, Sendable {
    // Enthusiast section
    public let instantBitrateMbps: Double?
    public let averageBitrateMbps: Double?
    public let observedFps: Double?
    public let droppedFrameCount: Int?
    public let forwardBufferSeconds: Double?
    public let cachedBytes: Int64?
    public let networkThroughputMbps: Double?
    public let networkTransferredBytes: Int64?
    public let avSyncGapMs: Double?

    // Engine diagnostics section
    public let producerRestartCount: Int
    public let muxedBytesLifetime: Int64
    public let serverBytesSentLifetime: Int64
    public let serverRequestCount: Int
    public let demuxerBytesFetched: Int64
    public let audioBridgeLiveBytes: Int
    public let rssMb: Int

    public init(
        instantBitrateMbps: Double?,
        averageBitrateMbps: Double?,
        observedFps: Double?,
        droppedFrameCount: Int?,
        forwardBufferSeconds: Double?,
        cachedBytes: Int64?,
        networkThroughputMbps: Double?,
        networkTransferredBytes: Int64?,
        avSyncGapMs: Double?,
        producerRestartCount: Int,
        muxedBytesLifetime: Int64,
        serverBytesSentLifetime: Int64,
        serverRequestCount: Int,
        demuxerBytesFetched: Int64,
        audioBridgeLiveBytes: Int,
        rssMb: Int
    ) {
        self.instantBitrateMbps = instantBitrateMbps
        self.averageBitrateMbps = averageBitrateMbps
        self.observedFps = observedFps
        self.droppedFrameCount = droppedFrameCount
        self.forwardBufferSeconds = forwardBufferSeconds
        self.cachedBytes = cachedBytes
        self.networkThroughputMbps = networkThroughputMbps
        self.networkTransferredBytes = networkTransferredBytes
        self.avSyncGapMs = avSyncGapMs
        self.producerRestartCount = producerRestartCount
        self.muxedBytesLifetime = muxedBytesLifetime
        self.serverBytesSentLifetime = serverBytesSentLifetime
        self.serverRequestCount = serverRequestCount
        self.demuxerBytesFetched = demuxerBytesFetched
        self.audioBridgeLiveBytes = audioBridgeLiveBytes
        self.rssMb = rssMb
    }
}

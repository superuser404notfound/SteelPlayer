import Foundation
import Libavcodec
import Libavutil

/// Reconstructs the `dec3` (EAC3) or `dac3` (AC3) sample-entry extradata
/// blob the mp4 muxer needs at `avformat_write_header` time, parsed
/// directly out of the first AC3 / EAC3 syncframe in a packet.
///
/// Why this exists: matroska's CodecPrivate doesn't carry the
/// pre-parsed bitstream info the mov muxer wants. Stream-copying
/// AC3 / EAC3 from MKV therefore fails at `avformat_write_header`
/// with -22 "Cannot write moov atom before packets parsed". The
/// long-standing workaround was to fall back to a FLAC bridge,
/// which wastes a decode→encode round-trip for codecs AVPlayer
/// would happily stream-copy and silently drops Atmos JOC metadata
/// from EAC3+JOC sources. By parsing the syncframe ourselves and
/// building the dec3 / dac3 box content, we patch the codecpar
/// up-front, the muxer accepts write_header, and stream-copy
/// engages with Atmos preserved.
///
/// Spec references:
/// - ETSI TS 102 366 V1.4.1 Annex F.6: `EC3SpecificBox` (dec3) and
///   `AC3SpecificBox` (dac3) layouts.
/// - ATSC A/52 (AC3): `syncinfo` + `bsi` syntax for the syncframe.
/// - ATSC A/52 Annex E (EAC3): `syncframe` and `bsi`.
enum AC3ExtradataReconstructor {

    // MARK: - Public API

    /// Build the `dac3` box content (codec-private bytes the mov muxer
    /// emits inside the `audioSampleEntry → dac3` atom) by parsing the
    /// first AC3 syncframe in `packetData`.
    ///
    /// Returns nil if no AC3 syncword is found within the first 256
    /// bytes, which is enough headroom for matroska's typical
    /// frame-on-frame packing.
    static func ac3ExtradataFromSyncframe(
        packetData: UnsafePointer<UInt8>,
        size: Int
    ) -> Data? {
        guard let syncOffset = findAC3SyncWord(packetData, size: size) else {
            return nil
        }
        var reader = BitReader(
            bytes: packetData.advanced(by: syncOffset),
            count: size - syncOffset
        )
        // syncword (16) + crc1 (16) — skip
        guard reader.skipBits(32) else { return nil }
        guard let fscod = reader.readBits(2),
              let frmsizecod = reader.readBits(6),
              let bsid = reader.readBits(5),
              let bsmod = reader.readBits(3),
              let acmod = reader.readBits(3) else {
            return nil
        }
        // bsid <= 8 means classic AC3; anything else is EAC3 (bsid==16)
        // or a future codec we don't know how to parse here. Bail —
        // caller falls back to the FLAC bridge for unknown variants.
        guard bsid <= 8 else { return nil }

        // Skip the conditional mix-level fields before lfeon. The
        // ATSC A/52 bsi() syntax inserts these depending on acmod:
        //   if ((acmod & 0x1) && (acmod != 0x1)) cmixlev 2 bits
        //   if (acmod & 0x4)                     surmixlev 2 bits
        //   if (acmod == 0x2)                    dsurmod 2 bits
        if (acmod & 0x1) != 0 && acmod != 0x1 {
            guard reader.skipBits(2) else { return nil }
        }
        if (acmod & 0x4) != 0 {
            guard reader.skipBits(2) else { return nil }
        }
        if acmod == 0x2 {
            guard reader.skipBits(2) else { return nil }
        }
        guard let lfeon = reader.readBits(1) else { return nil }

        // dac3 frmsizecod-to-bit_rate_code: the 6-bit AC3 frmsizecod
        // encodes (bit_rate, frame_size) pairs that collapse to a
        // single 5-bit bit_rate_code by integer division by 2 (every
        // pair of frmsizecod values shares the same bit rate; the
        // second value is for a slightly different frame size at the
        // same rate).
        let bitRateCode = frmsizecod >> 1

        // dac3 box content layout (ETSI TS 102 366 F.5):
        //   fscod          (2)
        //   bsid           (5)
        //   bsmod          (3)
        //   acmod          (3)
        //   lfeon          (1)
        //   bit_rate_code  (5)
        //   reserved       (5) = 0
        // Total: 24 bits = 3 bytes. The mov muxer wraps this in the
        // dac3 atom header automatically.
        var writer = BitWriter()
        writer.writeBits(fscod, count: 2)
        writer.writeBits(bsid, count: 5)
        writer.writeBits(bsmod, count: 3)
        writer.writeBits(acmod, count: 3)
        writer.writeBits(lfeon, count: 1)
        writer.writeBits(bitRateCode, count: 5)
        writer.writeBits(0, count: 5)
        return Data(writer.bytes)
    }

    /// Build the `dec3` box content for an EAC3 source. Parses the
    /// first EAC3 syncframe from `packetData` and emits a single-
    /// independent-substream descriptor. If `jocPresent` is true
    /// (signalled by the source codecpar's `profile == FF_PROFILE_EAC3_JOC`,
    /// which libavformat sets when the matroska BlockGroup tags or the
    /// EAC3 extension substream contains JOC metadata), the descriptor
    /// declares `num_dep_sub = 1` so AVPlayer's EAC3 decoder routes
    /// the JOC payload through and Atmos passthrough engages on a
    /// Atmos-capable AVR.
    ///
    /// Returns nil if no EAC3 syncword is found within the scan window.
    static func eac3ExtradataFromSyncframe(
        packetData: UnsafePointer<UInt8>,
        size: Int,
        jocPresent: Bool
    ) -> Data? {
        guard let syncOffset = findAC3SyncWord(packetData, size: size) else {
            return nil
        }
        var reader = BitReader(
            bytes: packetData.advanced(by: syncOffset),
            count: size - syncOffset
        )
        // syncword (16) — skip
        guard reader.skipBits(16) else { return nil }
        // EAC3 bsi() layout per ATSC A/52 Annex E.1.2.2:
        //   strmtyp        2
        //   substreamid    3
        //   frmsiz         11
        //   fscod          2
        //   if (fscod == 0x3) fscod2 2  (numblkscod implicit = 3)
        //   else             numblkscod 2
        //   acmod          3
        //   lfeon          1
        //   bsid           5
        //   ...
        guard reader.skipBits(2 + 3 + 11) else { return nil }
        guard let fscod = reader.readBits(2) else { return nil }
        // numblkscod field width is 2 either way; for fscod==3 it's
        // technically the fscod2 reduced-rate sub-field but it
        // occupies the same 2 bits. dec3 wants the original fscod
        // value (0..2 for native rates, 3 for reduced rate) so we
        // pass fscod through unchanged.
        guard reader.skipBits(2) else { return nil }
        guard let acmod = reader.readBits(3) else { return nil }
        guard let lfeon = reader.readBits(1) else { return nil }
        guard let bsid = reader.readBits(5) else { return nil }
        guard bsid >= 11 && bsid <= 16 else {
            // Not EAC3 (bsid==16) or a known EAC3-extension bsid.
            // Bail — caller falls back to FLAC bridge.
            return nil
        }

        // dec3 box content (ETSI TS 102 366 F.6) for a single
        // independent substream:
        //   data_rate          (13)  — kbps, derived from frmsiz +
        //                              fscod. We use 0 here; AVPlayer
        //                              doesn't gate on this value.
        //   num_ind_sub        (3)   = 0  (1 independent substream)
        //   per-substream(0):
        //     fscod            (2)
        //     bsid             (5)
        //     reserved         (1)   = 0
        //     asvc             (1)   = 0
        //     bsmod            (3)   = 0  (Complete Main; not in the
        //                                  EAC3 syncframe header at
        //                                  this offset, defaulting to
        //                                  the most common bsmod is
        //                                  safe — AVPlayer ignores it
        //                                  for routing decisions)
        //     acmod            (3)
        //     lfeon            (1)
        //     reserved         (3)   = 0
        //     num_dep_sub      (4)
        //     if num_dep_sub > 0:
        //       chan_loc       (9)   = 0  (channels at "centre back")
        //     else:
        //       reserved       (1)   = 0
        //
        // For non-JOC: 16 + 24 = 40 bits = 5 bytes.
        // For JOC:     16 + 32 = 48 bits = 6 bytes.
        let numDepSub: UInt32 = jocPresent ? 1 : 0

        var writer = BitWriter()
        writer.writeBits(0, count: 13)       // data_rate
        writer.writeBits(0, count: 3)        // num_ind_sub = 0 (= 1 stream)
        // independent substream 0
        writer.writeBits(fscod, count: 2)
        writer.writeBits(bsid, count: 5)
        writer.writeBits(0, count: 1)        // reserved
        writer.writeBits(0, count: 1)        // asvc
        writer.writeBits(0, count: 3)        // bsmod
        writer.writeBits(acmod, count: 3)
        writer.writeBits(lfeon, count: 1)
        writer.writeBits(0, count: 3)        // reserved
        writer.writeBits(numDepSub, count: 4)
        if numDepSub > 0 {
            writer.writeBits(0, count: 9)    // chan_loc
        } else {
            writer.writeBits(0, count: 1)    // reserved
        }
        return Data(writer.bytes)
    }

    // MARK: - Private helpers

    /// Find the AC3 / EAC3 syncword (0x0B77) in the first 256 bytes
    /// of `bytes`. The shared syncword lets a single scan handle both
    /// codecs; the bsid field after the header disambiguates.
    ///
    /// Returns the byte offset of the syncword's first byte, or nil
    /// if no syncword appears within the scan window. 256 bytes is
    /// generous — matroska's BlockGroup-with-multiple-frames pattern
    /// places frame boundaries at most ~64 bytes apart for AC3 / EAC3
    /// at typical bitrates.
    private static func findAC3SyncWord(_ bytes: UnsafePointer<UInt8>, size: Int) -> Int? {
        let limit = min(size - 1, 256)
        for i in 0..<limit {
            if bytes[i] == 0x0B && bytes[i + 1] == 0x77 {
                return i
            }
        }
        return nil
    }
}

// MARK: - BitReader / BitWriter

/// Big-endian MSB-first bit reader over an `UnsafePointer<UInt8>`
/// buffer. Used for syncframe parsing; matches the ATSC A/52 bit
/// numbering convention.
private struct BitReader {
    let bytes: UnsafePointer<UInt8>
    let count: Int
    var bitOffset: Int = 0

    mutating func readBits(_ n: Int) -> UInt32? {
        guard bitOffset + n <= count * 8, n <= 32 else { return nil }
        var value: UInt32 = 0
        for i in 0..<n {
            let byteIdx = (bitOffset + i) / 8
            let bitIdx = 7 - ((bitOffset + i) % 8)
            let bit = (UInt32(bytes[byteIdx]) >> bitIdx) & 1
            value = (value << 1) | bit
        }
        bitOffset += n
        return value
    }

    @discardableResult
    mutating func skipBits(_ n: Int) -> Bool {
        guard bitOffset + n <= count * 8 else { return false }
        bitOffset += n
        return true
    }
}

/// Big-endian MSB-first bit writer that accumulates into a `[UInt8]`
/// buffer. Matches the dac3 / dec3 atom byte layout.
private struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var bitOffset: Int = 0

    mutating func writeBits(_ value: UInt32, count: Int) {
        guard count >= 0 && count <= 32 else { return }
        for i in (0..<count).reversed() {
            let bit = UInt8((value >> i) & 1)
            let byteIdx = bitOffset / 8
            let bitIdx = 7 - (bitOffset % 8)
            if byteIdx >= bytes.count {
                bytes.append(0)
            }
            bytes[byteIdx] |= bit << bitIdx
            bitOffset += 1
        }
    }
}

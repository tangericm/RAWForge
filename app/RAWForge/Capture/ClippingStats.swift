import AVFoundation
import CoreVideo
import Foundation

/// Per-CFA-channel statistics computed from the real Bayer payload at capture
/// time (#8).
///
/// #8 is explicit that **clipping is a recorded number, never a fault**: it is
/// a judgement about a scene rather than a hardware failure, and the
/// workstation makes it better with the actual pixels and no daylight on the
/// screen. So nothing here decides anything. It records a distribution and
/// leaves the verdict to a reader.
///
/// That principle is load-bearing rather than stylistic, because the obvious
/// place to key a verdict is wrong: the DNG declares `WhiteLevel` 4095 against
/// `BlackLevel` 528, but saturation was **measured at 3039 above black**. A
/// "fraction clipped" computed against the declared range would report zero on
/// a frame that is more than half saturated. Recording the histogram means a
/// later, better saturation figure can be applied to frames already shot.
struct ClippingStats: Codable, Equatable {

    /// Why the statistics are absent, when they are. `AVCapturePhoto.pixelBuffer`
    /// is documented to carry raw sensor data for a RAW photo, but that is not
    /// guaranteed for every format, and a silent absence would be worse than a
    /// named one.
    let unavailableReason: String?

    let pixelFormat: String?
    let bufferWidth: Int?
    let bufferHeight: Int?

    /// The crop the statistics were computed over. #8 specifies the
    /// `ActiveArea`, which excludes the 192 padding columns.
    let activeArea: [Int]?
    let croppedWidth: Int?
    let croppedHeight: Int?

    /// **In DNG units, not buffer units.** Measured: `AVCapturePhoto.pixelBuffer`
    /// delivers 14-bit samples while the DNG stores 12-bit, so the buffer runs
    /// exactly 4x these values — a floor at 2112 against a declared `BlackLevel`
    /// of 528, and saturation at 14271 against a declared `WhiteLevel` of 4095
    /// (16380 scaled). Everything in `channels` below is in **buffer units**.
    let declaredBlackLevel: Double?
    let declaredWhiteLevel: Double?

    /// `declaredWhiteLevel` scaled into buffer units, so the declared ceiling
    /// and the measured distribution can be compared without the reader having
    /// to know the bit-depth difference. Derived, not measured.
    var declaredWhiteLevelInBufferUnits: Double? {
        guard let w = declaredWhiteLevel, let scale = bufferScaleOverDNG else { return nil }
        return w * scale
    }

    /// Inferred from the capture format's bit depth against the DNG's.
    let bufferScaleOverDNG: Double?

    let channels: [Channel]

    struct Channel: Codable, Equatable {
        /// Position in the 2x2 CFA, reading (0,0) (0,1) (1,0) (1,1).
        let cfaPosition: Int
        /// R, G, or B, derived from the capture format's fourCC.
        let colour: String

        let count: Int
        let min: Int
        let max: Int
        let mean: Double
        let p50: Int, p90: Int, p99: Int, p999: Int

        /// Pixels at the frame's exact maximum. **Unreliable as a saturation
        /// measure on its own**: a handful of outlier pixels can read above the
        /// saturation plateau, in which case this counts the outliers and
        /// misses the plateau entirely. Measured on a saturated green channel
        /// whose p50 and p99 both sat at 14271 while this field reported 1.
        let countAtMax: Int

        /// The single most common value in the channel, and how many pixels
        /// hold it. Pure measurement, no threshold and no classification.
        ///
        /// On a saturated channel the mode **is** the saturation point, because
        /// every clipped pixel lands on exactly one value — measured at 14271
        /// holding 8.7% of blue on a blown rung. On an unsaturated channel it is
        /// merely the peak of the scene histogram and means nothing in
        /// particular. Distinguishing the two is a judgement, and per #8 that
        /// belongs to the workstation, not to this device.
        ///
        /// The unambiguous saturation signature is already here without any
        /// heuristic: `p50 == p99` means over half the channel sits at one
        /// value, and only clipping does that.
        let modeValue: Int
        let modeCount: Int
        var modeFraction: Double { count > 0 ? Double(modeCount) / Double(count) : 0 }

        /// 256-bin histogram over the full 16-bit range, so a reader can apply
        /// any saturation threshold retrospectively. Exact percentiles above
        /// come from the full-resolution histogram, not from these bins.
        let histogram256: [Int]
    }

    static func unavailable(_ reason: String) -> ClippingStats {
        ClippingStats(unavailableReason: reason, pixelFormat: nil, bufferWidth: nil,
                      bufferHeight: nil, activeArea: nil, croppedWidth: nil, croppedHeight: nil,
                      declaredBlackLevel: nil, declaredWhiteLevel: nil,
                      bufferScaleOverDNG: nil, channels: [])
    }

    // MARK: - Computation

    /// One pass over the Bayer payload, four full 16-bit histograms.
    ///
    /// A 16-bit histogram per channel is 256 KB total and gives exact
    /// percentiles for free, which a coarse histogram would not. #8's reason
    /// for computing here rather than downstream is that it is nearly free at
    /// capture and expensive to re-derive from 25 MB files later.
    static func compute(from photo: AVCapturePhoto,
                        bayerFormat: OSType,
                        activeArea: [Int]?,
                        blackLevel: Double?,
                        whiteLevel: Double?) -> ClippingStats {
        guard let buffer = photo.pixelBuffer else {
            return .unavailable("AVCapturePhoto.pixelBuffer was nil for this RAW photo")
        }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        guard CVPixelBufferGetPlaneCount(buffer) <= 1 else {
            return .unavailable("expected a single-plane Bayer buffer, got \(CVPixelBufferGetPlaneCount(buffer)) planes")
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return .unavailable("could not lock the pixel buffer base address")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard bytesPerRow >= width * 2 else {
            return .unavailable("buffer stride \(bytesPerRow) is too small for a 16-bit \(width)-wide row")
        }

        // ActiveArea is [top, left, bottom, right] in DNG. Fall back to the
        // whole buffer, recording that that is what happened.
        var top = 0, left = 0, bottom = height, right = width
        if let a = activeArea, a.count == 4 {
            top = max(0, a[0]); left = max(0, a[1])
            bottom = min(height, a[2]); right = min(width, a[3])
        }
        guard bottom > top, right > left else {
            return .unavailable("active area \(activeArea ?? []) does not intersect the buffer")
        }

        // Four histograms, one per CFA position, indexed (row & 1) * 2 + (col & 1).
        //
        // Flat storage with unchecked pointer access rather than a 2D array:
        // this loop runs 12.2 million times per frame, and a bracket of 8 runs
        // it eight times. Nested Swift arrays with bounds checking turn a
        // sub-second pass into a multi-second one in a debug build.
        var flat = [UInt32](repeating: 0, count: 4 * 65536)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        flat.withUnsafeMutableBufferPointer { h in
            for row in top..<bottom {
                let rowPtr = (bytes + row * bytesPerRow).withMemoryRebound(to: UInt16.self, capacity: width) { $0 }
                let rowParity = (row & 1) * 2
                var col = left
                while col < right {
                    h[(rowParity + (col & 1)) << 16 + Int(rowPtr[col])] &+= 1
                    col += 1
                }
            }
        }
        let hist: [[Int]] = (0..<4).map { pos in
            (0..<65536).map { Int(flat[(pos << 16) + $0]) }
        }

        let labels = colourLabels(for: bayerFormat)
        var channels: [Channel] = []
        for pos in 0..<4 {
            let h = hist[pos]
            let total = h.reduce(0, +)
            guard total > 0 else { continue }
            var seen = 0, lo = 0, hi = 0, sum = 0.0
            var p50 = 0, p90 = 0, p99 = 0, p999 = 0
            var first = true
            for (value, n) in h.enumerated() where n > 0 {
                if first { lo = value; first = false }
                hi = value
                sum += Double(value) * Double(n)
                let before = seen
                seen += n
                if before < total / 2 && seen >= total / 2 { p50 = value }
                if before < total * 90 / 100 && seen >= total * 90 / 100 { p90 = value }
                if before < total * 99 / 100 && seen >= total * 99 / 100 { p99 = value }
                if before < total * 999 / 1000 && seen >= total * 999 / 1000 { p999 = value }
            }
            var bins = [Int](repeating: 0, count: 256)
            for (value, n) in h.enumerated() where n > 0 { bins[value >> 8] += n }

            var modeValue = lo, modeCount = 0
            for value in lo...hi where h[value] > modeCount {
                modeValue = value; modeCount = h[value]
            }

            channels.append(Channel(
                cfaPosition: pos, colour: labels[pos], count: total,
                min: lo, max: hi, mean: sum / Double(total),
                p50: p50, p90: p90, p99: p99, p999: p999,
                countAtMax: h[hi], modeValue: modeValue, modeCount: modeCount,
                histogram256: bins))
        }

        return ClippingStats(
            unavailableReason: nil,
            pixelFormat: fourCC(format),
            bufferWidth: width, bufferHeight: height,
            activeArea: activeArea,
            croppedWidth: right - left, croppedHeight: bottom - top,
            declaredBlackLevel: blackLevel, declaredWhiteLevel: whiteLevel,
            bufferScaleOverDNG: bufferScale(for: format, declaredWhite: whiteLevel),
            channels: channels)
    }

    /// The capture format's fourCC names the CFA order directly — `bgg4` is
    /// BGGR, `rgg4` is RGGB — which is why the label does not have to be
    /// inferred from the DNG's `CFAPattern`. Measured: 1x is BGGR while 0.5x
    /// and telephoto are RGGB on the same phone.
    private static func colourLabels(for format: OSType) -> [String] {
        switch fourCCRaw(format) {
        case "bgg4": return ["B", "G", "G", "R"]
        case "rgg4": return ["R", "G", "G", "B"]
        case "grb4": return ["G", "R", "B", "G"]
        case "gbr4": return ["G", "B", "R", "G"]
        default:     return ["?", "?", "?", "?"]
        }
    }

    /// 14-bit Bayer buffer against a 12-bit DNG gives exactly 4x. Derived from
    /// the format name and the declared white level rather than hardcoded, so a
    /// device that stores something else is visible instead of silently wrong.
    private static func bufferScale(for format: OSType, declaredWhite: Double?) -> Double? {
        guard let w = declaredWhite, w > 0 else { return nil }
        guard fourCCRaw(format).hasSuffix("4") else { return nil }   // 14Bayer_*
        let bufferFullScale = 16383.0
        let dngFullScale = w <= 4095 ? 4095.0 : 65535.0
        return (bufferFullScale + 1) / (dngFullScale + 1)
    }

    private static func fourCCRaw(_ code: OSType) -> String {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                     UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "?"
    }
}

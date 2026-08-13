import Foundation

/// A minimal TIFF/DNG IFD walker, for the tags ImageIO coerces.
///
/// This exists because of one tag. `NoiseReductionApplied` is a RATIONAL, and
/// the DNG spec makes **0/0 mean *unknown*, not zero** — but ImageIO hands back
/// a coerced `0` for both `0/0` and `0/1`, which are opposite claims. Recording
/// the coerced value would put "no noise reduction was applied" in the log when
/// the file actually says "nobody knows", and that tag is the whole reason
/// ProRAW is disqualified (#5, #14 item 14).
///
/// `ImageWidth` is read here too: ImageIO's `kCGImagePropertyPixelWidth`
/// reports the *cropped* width, hiding the padding columns that a photometric
/// reconstruction has to crop for itself.
enum DNGRawTags {

    /// A rational kept unreduced, so 0/0 stays distinguishable from 0/1.
    struct Rational: Codable, Equatable {
        let numerator: UInt32
        let denominator: UInt32

        var isUnknown: Bool { denominator == 0 }
        var value: Double? { denominator == 0 ? nil : Double(numerator) / Double(denominator) }

        var description: String {
            denominator == 0
                ? "\(numerator)/0 — UNKNOWN per the DNG spec, not zero"
                : "\(numerator)/\(denominator) = \(Double(numerator) / Double(denominator))"
        }
    }

    static let noiseReductionApplied: UInt16 = 50935
    static let imageWidthTag: UInt16 = 256

    struct Reading {
        var noiseReductionApplied: Rational?
        var storedImageWidth: UInt32?
    }

    static func read(_ data: Data) -> Reading {
        var out = Reading()
        guard data.count > 8 else { return out }

        let little: Bool
        switch (data[0], data[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return out
        }
        func u16(_ o: Int) -> UInt16? {
            guard o >= 0, o + 2 <= data.count else { return nil }
            let a = UInt16(data[o]), b = UInt16(data[o + 1])
            return little ? a | (b << 8) : (a << 8) | b
        }
        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= data.count else { return nil }
            let b = (0..<4).map { UInt32(data[o + $0]) }
            return little ? b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)
                          : (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]
        }

        guard u16(2) == 42, let first = u32(4) else { return out }

        // Walk IFD0, then any SubIFDs it names — Apple puts the CFA image in a
        // SubIFD on some builds and in IFD0 on others, and the tag follows it.
        var queue: [Int] = [Int(first)]
        var visited = Set<Int>()
        var widths: [UInt32] = []

        while let offset = queue.popLast() {
            guard !visited.contains(offset), visited.count < 16,
                  let count = u16(offset) else { continue }
            visited.insert(offset)

            for i in 0..<Int(count) {
                let entry = offset + 2 + i * 12
                guard let tag = u16(entry), let type = u16(entry + 2),
                      let n = u32(entry + 4), let valueOrOffset = u32(entry + 8) else { continue }

                switch tag {
                case noiseReductionApplied where type == 5 && n >= 1:
                    // RATIONAL is 8 bytes, so it never fits inline — the field
                    // is always an offset.
                    let at = Int(valueOrOffset)
                    if let num = u32(at), let den = u32(at + 4) {
                        out.noiseReductionApplied = Rational(numerator: num, denominator: den)
                    }
                case imageWidthTag:
                    // SHORT is stored in the low half of the value field.
                    if type == 3, let w = u16(entry + 8) { widths.append(UInt32(w)) }
                    else if type == 4 { widths.append(valueOrOffset) }
                case 330: // SubIFDs
                    if n == 1 { queue.append(Int(valueOrOffset)) }
                    else {
                        for k in 0..<Int(n) {
                            if let sub = u32(Int(valueOrOffset) + k * 4) { queue.append(Int(sub)) }
                        }
                    }
                default: break
                }
            }
            if let next = u32(offset + 2 + Int(count) * 12), next != 0 { queue.append(Int(next)) }
        }

        // The CFA image is the largest one in the file; thumbnails are smaller.
        out.storedImageWidth = widths.max()
        return out
    }
}

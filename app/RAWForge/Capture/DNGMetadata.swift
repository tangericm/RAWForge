import ImageIO
import Foundation

/// Reads the third witness (#9) back out of the DNG the app just wrote.
///
/// ImageIO will not hand back undemosaiced Bayer pixels, so this is a metadata
/// read only — which is all the witness needs to be. Tags are looked up by DNG
/// tag name where the Swift constant may be unavailable, so a missing constant
/// degrades to `nil` rather than failing to compile.
enum DNGMetadata {

    static func read(_ data: Data) -> FrameRecord.DNGWitness {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return empty
        }
        let dng  = props[kCGImagePropertyDNGDictionary]  as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]

        // ImageIO coerces the one tag that must not be coerced, and reports a
        // cropped width. Both come from the IFD directly instead.
        let raw = DNGRawTags.read(data)

        return FrameRecord.DNGWitness(
            exposureTimeSeconds: exif?[kCGImagePropertyExifExposureTime] as? Double,
            iso: (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first,
            asShotNeutral: doubles(dng?[kCGImagePropertyDNGAsShotNeutral]),
            blackLevel: doubles(dng?[kCGImagePropertyDNGBlackLevel]),
            whiteLevel: doubles(dng?[kCGImagePropertyDNGWhiteLevel]),
            cfaPattern: describe(dng?[tag("CFAPattern")] ?? exif?[kCGImagePropertyExifCFAPattern]),
            activeArea: ints(dng?[tag("ActiveArea")]),
            uniqueCameraModel: dng?[kCGImagePropertyDNGUniqueCameraModel] as? String,
            localizedCameraModel: dng?[kCGImagePropertyDNGLocalizedCameraModel] as? String,
            noiseReductionAppliedCoerced: describe(dng?[tag("NoiseReductionApplied")]),
            noiseReductionApplied: raw.noiseReductionApplied,
            noiseProfile: doubles(dng?[kCGImagePropertyDNGNoiseProfile]),
            dateTimeOriginal: exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            subsecTimeOriginal: exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String,
            storedImageWidth: raw.storedImageWidth.map(Int.init),
            imageWidth: props[kCGImagePropertyPixelWidth] as? Int,
            imageHeight: props[kCGImagePropertyPixelHeight] as? Int)
    }

    /// The full dictionary dump, for the cases where a named tag is missing and
    /// what is actually in the file is the question.
    static func dump(_ data: Data) -> [String: String] {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (group, key) in [("DNG", kCGImagePropertyDNGDictionary),
                             ("EXIF", kCGImagePropertyExifDictionary),
                             ("TIFF", kCGImagePropertyTIFFDictionary)] {
            guard let d = props[key] as? [CFString: Any] else { continue }
            for (k, v) in d { out["\(group).\(k as String)"] = describe(v) ?? "<nil>" }
        }
        return out
    }

    private static let empty = FrameRecord.DNGWitness(
        exposureTimeSeconds: nil, iso: nil, asShotNeutral: nil, blackLevel: nil,
        whiteLevel: nil, cfaPattern: nil, activeArea: nil, uniqueCameraModel: nil,
        localizedCameraModel: nil, noiseReductionAppliedCoerced: nil, noiseReductionApplied: nil, noiseProfile: nil,
        dateTimeOriginal: nil, subsecTimeOriginal: nil, storedImageWidth: nil, imageWidth: nil, imageHeight: nil)

    private static func tag(_ name: String) -> CFString { name as CFString }

    private static func doubles(_ v: Any?) -> [Double]? {
        if let a = v as? [Double] { return a }
        if let a = v as? [NSNumber] { return a.map(\.doubleValue) }
        if let n = v as? NSNumber { return [n.doubleValue] }
        return nil
    }

    private static func ints(_ v: Any?) -> [Int]? {
        if let a = v as? [Int] { return a }
        if let a = v as? [NSNumber] { return a.map(\.intValue) }
        return nil
    }

    private static func describe(_ v: Any?) -> String? {
        guard let v, !(v is NSNull) else { return nil }
        if let d = v as? Data { return d.map { String(format: "%02x", $0) }.joined() }
        if let a = v as? [Any] { return "[" + a.map { "\($0)" }.joined(separator: ", ") + "]" }
        return "\(v)"
    }
}

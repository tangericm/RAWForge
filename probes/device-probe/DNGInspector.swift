import ImageIO
import Foundation

/// Reads what ImageIO will surface from a DNG's metadata on device. It will not
/// hand back raw Bayer pixels without demosaicing, so the pixel-limb comparison
/// (item 3) is done off device on the saved files — but the metadata limb, and
/// item 14's NoiseReductionApplied, live here.
enum DNGInspector {

    /// Full dump of the DNG / EXIF / TIFF dictionaries, plus the tags the probe
    /// cares about pulled out by name. Dumping everything is deliberate: if a
    /// specific ImageIO constant is missing or renamed, the raw dictionary still
    /// shows what is actually in the file.
    static func report(_ data: Data) -> String {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return "  <ImageIO could not read the DNG>"
        }

        var out: [String] = []

        // Named tags the spike is about.
        let dng  = props[kCGImagePropertyDNGDictionary] as? [CFString: Any]
        out.append("  AsShotNeutral: \(fmt(dng?[kCGImagePropertyDNGAsShotNeutral]))")
        out.append("  BlackLevel: \(fmt(dng?[kCGImagePropertyDNGBlackLevel]))")
        out.append("  WhiteLevel: \(fmt(dng?[kCGImagePropertyDNGWhiteLevel]))")
        out.append("  NoiseProfile: \(fmt(dng?[kCGImagePropertyDNGNoiseProfile]))")
        out.append("  NoiseReductionApplied: \(fmt(dng?[tag("NoiseReductionApplied")]))")
        out.append("  UniqueCameraModel: \(fmt(dng?[kCGImagePropertyDNGUniqueCameraModel]))")
        out.append("  ActiveArea: \(fmt(dng?[tag("ActiveArea")]))")

        // Full dictionaries, so nothing surfaced-by-the-OS is lost.
        out.append("  --- full DNG dictionary ---")
        out.append(dumpDict(dng))
        out.append("  --- EXIF dictionary ---")
        out.append(dumpDict(props[kCGImagePropertyExifDictionary] as? [CFString: Any]))
        out.append("  --- TIFF dictionary ---")
        out.append(dumpDict(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]))

        return out.joined(separator: "\n")
    }

    private static func dumpDict(_ d: [CFString: Any]?) -> String {
        guard let d, !d.isEmpty else { return "    <none>" }
        return d.keys
            .map { $0 as String }
            .sorted()
            .map { "    \($0) = \(fmt(d[$0 as CFString]))" }
            .joined(separator: "\n")
    }

    private static func fmt(_ v: Any?) -> String {
        switch v {
        case nil: return "<absent>"
        case let a as [Any]: return "[" + a.map { "\($0)" }.joined(separator: ", ") + "]"
        default: return "\(v!)"
        }
    }

    /// ImageIO's DNG-dictionary keys resolve to the DNG tag names themselves
    /// (e.g. "BlackLevel", "NoiseReductionApplied"). For tags whose Swift
    /// constant may be unavailable on the SDK, look up by that tag string so the
    /// file always compiles. A miss prints <absent> — which, for
    /// NoiseReductionApplied, is itself the answer: unknown, not zero.
    private static func tag(_ name: String) -> CFString { name as CFString }
}

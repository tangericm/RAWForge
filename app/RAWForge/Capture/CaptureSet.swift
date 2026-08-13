import Foundation

/// One rung: what the protocol demands of a single frame.
///
/// A capture set is an ordered list of these (#8). Nothing here is derived from
/// the scene — these are authored numbers, and that is the entire difference
/// between this app and a camera.
struct CaptureSpec: Codable, Equatable, Identifiable {
    let shutterSeconds: Double
    let iso: Float

    var id: String { "\(shutterSeconds)@\(iso)" }

    var shutterLabel: String {
        shutterSeconds >= 1
            ? String(format: "%.1fs", shutterSeconds)
            : "1/\(Int((1 / shutterSeconds).rounded()))"
    }
}

/// A rung that could not be shot, kept rather than silently clamped.
///
/// #8 settled this: rails are validated at authoring time and out-of-range
/// rungs are **dropped and recorded**, never clamped. A clamped rung captures
/// at a value nobody asked for and reads back as though it were the request —
/// exactly the after-the-fact inference this app exists to eliminate.
struct DroppedRung: Codable, Equatable {
    let spec: CaptureSpec
    let reason: String
}

/// An ordered list of specs, authored on device and inlined into the session.
///
/// #8's amendment allows authoring mid-shoot with the version auto-bumped, and
/// requires the full definition be inlined rather than referenced by id — so a
/// reader holding only the session knows exactly what protocol produced it,
/// with no external registry to consult.
struct CaptureSet: Codable, Equatable {
    let name: String
    let version: Int
    let specs: [CaptureSpec]

    /// How the set was produced. A sweep is a *generator*, not a separate kind
    /// of definition (#8) — the rendered specs above are what actually ran, and
    /// this records what asked for them.
    let generator: Generator

    enum Generator: Codable, Equatable {
        case manual
        case repeated(spec: CaptureSpec, count: Int)
        case shutterSweep(base: CaptureSpec, stopsPerRung: Double, rungs: Int)

        var describe: String {
            switch self {
            case .manual:
                return "manual"
            case .repeated(let s, let n):
                return "repeat ×\(n) at \(s.shutterLabel) ISO \(Int(s.iso))"
            case .shutterSweep(let b, let stops, let n):
                return "shutter sweep \(n) rungs, \(stops) stop(s) apart from \(b.shutterLabel) ISO \(Int(b.iso))"
            }
        }
    }

    // MARK: - Generators

    /// The fixed-parameter run: nothing changes between frames, so nothing
    /// needs to settle and the length is bounded only by storage, thermal and
    /// battery (#10's hard faults). This is what a dark-frame mirror and a
    /// repeat block are made of (#15).
    static func repeated(_ spec: CaptureSpec, count: Int, name: String = "repeat", version: Int = 1) -> CaptureSet {
        CaptureSet(name: name, version: version,
                   specs: Array(repeating: spec, count: max(1, count)),
                   generator: .repeated(spec: spec, count: max(1, count)))
    }

    /// Geometric spacing, equal in stops (#8) — each rung doubles or halves the
    /// shutter relative to its neighbour, so the ladder is even in exposure
    /// rather than even in seconds.
    static func shutterSweep(base: CaptureSpec, stopsPerRung: Double = 1,
                             rungs: Int, name: String = "sweep", version: Int = 1) -> CaptureSet {
        let n = max(1, rungs)
        // Centre the ladder on the base rung so the authored value is shot.
        let offset = Double(n - 1) / 2
        let specs = (0..<n).map { i -> CaptureSpec in
            let stops = (Double(i) - offset) * stopsPerRung
            return CaptureSpec(shutterSeconds: base.shutterSeconds * pow(2, stops), iso: base.iso)
        }
        return CaptureSet(name: name, version: version, specs: specs,
                          generator: .shutterSweep(base: base, stopsPerRung: stopsPerRung, rungs: n))
    }

    // MARK: - Rails

    struct Validated {
        let kept: [CaptureSpec]
        let dropped: [DroppedRung]
    }

    /// Validates every rung against one sensor's actual rails. Out-of-range
    /// rungs are removed and the reason recorded; nothing is clamped.
    func validated(against sensor: SensorCapability) -> Validated {
        var kept: [CaptureSpec] = []
        var dropped: [DroppedRung] = []
        for spec in specs {
            if let lo = sensor.minExposureSeconds, spec.shutterSeconds < lo {
                dropped.append(DroppedRung(spec: spec, reason: String(
                    format: "shutter %.6fs below the sensor floor of %.6fs", spec.shutterSeconds, lo)))
            } else if let hi = sensor.maxExposureSeconds, spec.shutterSeconds > hi {
                dropped.append(DroppedRung(spec: spec, reason: String(
                    format: "shutter %.6fs above the sensor ceiling of %.3fs", spec.shutterSeconds, hi)))
            } else if let lo = sensor.minISO, spec.iso < lo {
                dropped.append(DroppedRung(spec: spec, reason: String(
                    format: "ISO %.0f below the sensor floor of %.0f", spec.iso, lo)))
            } else if let hi = sensor.maxISO, spec.iso > hi {
                dropped.append(DroppedRung(spec: spec, reason: String(
                    format: "ISO %.0f above the sensor ceiling of %.0f", spec.iso, hi)))
            } else {
                kept.append(spec)
            }
        }
        return Validated(kept: kept, dropped: dropped)
    }
}

/// How a capture set is executed. Both are first-class (#8) — the choice is
/// about inter-frame gap, not about what can be expressed.
enum ExecutionMode: String, Codable, CaseIterable, Identifiable {
    /// Unbounded. One `setExposureModeCustom` per rung, each awaited, so the
    /// cost is a settle per *change*. With identical rungs nothing changes and
    /// nothing settles, which is why a repeat block has no ceiling.
    case sequential

    /// One hardware request carrying per-frame parameters, capped by
    /// `maxBracketedCapturePhotoCount`. The device is never reconfigured
    /// mid-run, so the inter-frame gap is pipeline-bound rather than
    /// convergence-bound — the whole reason to prefer it for a short ladder
    /// that must share a pose.
    case hardwareBracket

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sequential:      return "Sequential"
        case .hardwareBracket: return "Bracket (≤ max)"
        }
    }
}

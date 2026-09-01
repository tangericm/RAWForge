import CoreGraphics
import Foundation

/// What the station intends to do about focus, per sensor.
///
/// Focus lives on the **station**, not on the capture set, and that placement is
/// the whole design. A `CaptureSet` is authored at a desk and reused across
/// scenes; `lensPosition` is a normalised lens *actuator* position with no
/// meaning away from the thing being focused on. A protocol carrying "focus =
/// 0.62" would reproduce perfectly while meaning something different every time
/// it ran, which is precisely the determinism this app refuses to fake.
///
/// So focus is chosen at the pose, with a live preview in front of the operator,
/// and recorded — never authored in advance.
struct FocusPlan: Codable, Equatable {

    /// How one sensor's focus is decided.
    enum Intent: Codable, Equatable {
        /// Autofocus runs at the swap, converges, and is then locked. The
        /// default, and strictly more determinism than leaving focus running.
        case automatic

        /// Autofocus runs at a point the operator chose, then locks.
        ///
        /// Stored in **`AVCaptureDevice` coordinates**, not view coordinates —
        /// normalised to the sensor's own picture area with the origin at the
        /// top left of its native landscape orientation. That is the space
        /// `AVCaptureVideoPreviewLayer.captureDevicePointConverted(fromLayerPoint:)`
        /// produces, and the only one where a point stays meaningful when the
        /// preview is rotated, letterboxed, or drawn at a different size.
        case point(x: Double, y: Double)

        /// A lens position set directly, 0–1. Only meaningful because the
        /// operator set it while watching this sensor's preview.
        case manual(lensPosition: Double)

        var label: String {
            switch self {
            case .automatic:      return "automatic"
            case .point:          return "point"
            case .manual:         return "manual"
            }
        }

        var pointOfInterest: CGPoint? {
            if case let .point(x, y) = self { return CGPoint(x: x, y: y) }
            return nil
        }

        var lensPosition: Double? {
            if case let .manual(p) = self { return p }
            return nil
        }
    }

    /// Keyed by `SensorCapability.Sensor.rawValue`. A sensor with no entry is
    /// `.automatic` — absence is a real state and not a missing one.
    var bySensor: [String: Intent] = [:]

    subscript(sensor: SensorCapability.Sensor) -> Intent {
        get { bySensor[sensor.rawValue] ?? .automatic }
        set { bySensor[sensor.rawValue] = newValue }
    }

    /// True when the operator has said anything at all beyond the default.
    var isCustomised: Bool { bySensor.values.contains { $0 != .automatic } }

    /// One line for the plan screen.
    func summary(for sensors: [SensorCapability.Sensor]) -> String {
        guard !sensors.isEmpty else { return "automatic" }
        let set = sensors.filter { self[$0] != .automatic }
        if set.isEmpty { return "automatic" }
        if set.count == sensors.count { return "set on all \(sensors.count)" }
        return "set on \(set.map(\.rawValue).joined(separator: ", "))"
    }
}

/// A focus decision with everything already resolved for one sensor.
///
/// This belongs to the capture domain rather than to `CaptureRig`: both the
/// station controller and the live camera adapter exchange it, and neither
/// should have to name the other's concrete type.
struct FocusResolution {
    var intent: FocusPlan.Intent = .automatic

    /// Already in capture-device coordinates, already mapped.
    var point: CGPoint?
    var mappedFrom: String?

    /// A lens position measured earlier on this same sensor.
    var restore: Float?
    var note: String?
}

/// What focus carries across a sensor swap, and what cannot.
///
/// A station is one pose, and every set in it should be focused the same way.
/// The complication is that "the same way" means different things depending on
/// what is being carried:
///
/// - **A lens position carries within a sensor and nowhere else.** It is an
///   actuator coordinate. Re-commanding it on the sensor that produced it is
///   exact; carrying it to a different sensor would silently mean a different
///   distance, so it is never attempted.
/// - **A focus point does not carry at all, here.** Mapping one between sensors
///   is possible (`FocusGeometry`) but only approximately, so the mapping is
///   done once in the pre-flight where the operator can see where it landed —
///   not silently at the pose.
///
/// The consequence is the rule this type implements: a station that returns to
/// a sensor it has already focused **restores that sensor's own measurement
/// exactly**, rather than re-running autofocus and drifting. A station arriving
/// at a sensor for the first time acquires focus fresh, which is the correct
/// answer to "the sensor changed — now what?"
struct FocusContinuity {

    /// The lens position each sensor settled at, this station. Cleared between
    /// stations, because a pose is the scope of a focus decision.
    private(set) var achieved: [String: Float] = [:]

    mutating func reset() { achieved.removeAll() }

    /// What to ask the rig for, bringing this sensor up.
    func resolution(for sensor: SensorCapability.Sensor,
                    plan: FocusPlan) -> FocusResolution {
        let intent = plan[sensor]
        var r = FocusResolution(intent: intent)

        switch intent {
        case .manual:
            // Already exact. Nothing to restore and nothing to hunt for.
            return r

        case .point(let x, let y):
            r.point = CGPoint(x: x, y: y)

        case .automatic:
            break
        }

        // Seen this sensor already at this station: put the lens back exactly
        // where it was rather than asking autofocus for the same answer twice
        // and getting two.
        if let previous = achieved[sensor.rawValue] {
            r.restore = previous
            r.note = "restored from this station's earlier set on \(sensor.rawValue)"
        }
        return r
    }

    /// Banks what the rig actually achieved, so a later set on the same sensor
    /// can be made identical to this one.
    mutating func record(_ focus: FrameRecord.Focus, for sensor: SensorCapability.Sensor) {
        // Only a held lock is worth restoring. A position read off a lens that
        // was never locked describes where it drifted to, not where it was put.
        guard focus.wasHeld, let p = focus.lensPosition else { return }
        achieved[sensor.rawValue] = p
    }
}

/// Moving a point between two sensors that are looking at the same scene.
///
/// ## Why this exists
///
/// The operator taps a subject once. The station may then swap to a sensor with
/// a different field of view, and the tap has to go somewhere. Re-tapping on
/// every sensor is the honest alternative, but it is three taps at the pose to
/// express one intention, so the app maps the point and *shows the operator
/// where it landed* rather than asserting the mapping is right.
///
/// ## The mapping
///
/// For a normalised coordinate `u` on an axis with horizontal field of view `φ`,
/// the angle off-centre is `θ = atan(2(u − 0.5)·tan(φ/2))`. Converting into a
/// second sensor and back out gives, exactly:
///
///     u' = 0.5 + (u − 0.5) · tan(φ_from/2) / tan(φ_to/2)
///
/// The same scale applies to **both** axes. That is not an approximation: the
/// vertical half-angle satisfies `tan(φᵥ/2) = tan(φₕ/2)·(H/W)`, so as long as
/// the two sensors share an aspect ratio — every rear sensor here runs the 4:3
/// photo preset — the aspect terms cancel and one factor covers both axes.
///
/// ## What it assumes, stated rather than buried
///
/// The lenses are physically separated by roughly 9 mm, so this is exact only at
/// infinity. Parallax error is about `baseline / distance`: ~0.5° at 1 m, ~1.9°
/// at 30 cm, which against a 70° frame is under 3% of frame width. Small, and
/// largest exactly where focus is most critical — which is the reason the result
/// is drawn on the preview for the operator to accept, and the reason nothing
/// here silently clamps an out-of-frame point into the frame.
enum FocusGeometry {

    /// Where a point lands in another sensor's frame.
    enum Mapping: Equatable {
        /// The point has a counterpart in the destination frame.
        case inside(CGPoint)

        /// The scene point is outside what the destination sensor can see —
        /// which is the ordinary case mapping an off-centre ultra-wide tap onto
        /// the wide. Carries the unclamped position so a caller can say *how
        /// far* out it fell, and never pretends it is a usable ROI.
        case outsideFrame(CGPoint)

        /// A field of view was not reported, so no mapping is possible.
        case unknown

        var usablePoint: CGPoint? {
            if case let .inside(p) = self { return p }
            return nil
        }
    }

    /// The single scale factor relating the two frames. Greater than 1 mapping
    /// from a wider sensor to a narrower one — points spread apart, because the
    /// narrow sensor sees a crop of what the wide one saw.
    static func scale(fromFieldOfView from: Double, toFieldOfView to: Double) -> Double? {
        guard from > 0, from < 180, to > 0, to < 180 else { return nil }
        let a = tan(from / 2 * .pi / 180)
        let b = tan(to / 2 * .pi / 180)
        guard b > 0 else { return nil }
        return a / b
    }

    static func map(point: CGPoint,
                    fromFieldOfView from: Double,
                    toFieldOfView to: Double) -> Mapping {
        guard let k = scale(fromFieldOfView: from, toFieldOfView: to) else { return .unknown }
        let mapped = CGPoint(x: 0.5 + (point.x - 0.5) * k,
                             y: 0.5 + (point.y - 0.5) * k)
        let inside = (0...1).contains(mapped.x) && (0...1).contains(mapped.y)
        return inside ? .inside(mapped) : .outsideFrame(mapped)
    }

    /// Angular parallax error of the mapping at a given subject distance, in
    /// degrees — reported rather than corrected, because correcting it would
    /// need the distance, and the app has no way to know it.
    ///
    /// `baselineMillimetres` is the lens separation. iPhone rear modules sit
    /// within about a centimetre of each other.
    static func parallaxErrorDegrees(subjectDistanceMetres d: Double,
                                     baselineMillimetres b: Double = 9) -> Double? {
        guard d > 0, b > 0 else { return nil }
        return atan((b / 1000) / d) * 180 / .pi
    }
}

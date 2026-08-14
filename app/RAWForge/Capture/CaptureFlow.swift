import Foundation

/// One entry in a station's shot list: a protocol, on a sensor.
///
/// A station is a pose and may hold several capture sets across the three rear
/// sensors (#7). The sensor is an attribute of the entry, not of the station.
struct ShotListEntry: Codable, Equatable, Identifiable {
    var id: String { "\(index)-\(sensor.rawValue)-\(captureSet.name)" }
    let index: Int
    let sensor: SensorCapability.Sensor
    let captureSet: CaptureSet

    var frameCount: Int { captureSet.specs.count }
    var label: String { "\(sensor.rawValue) · \(captureSet.name) v\(captureSet.version)" }
}

/// The station flow, as settled in `prototypes/station-flow.prototype.html`
/// for [#10](https://github.com/tangericm/RAWForge/issues/10).
///
/// The phases are not cosmetic. Each one exists because something must finish
/// before the next thing may start, and the prototype's notes are design
/// decisions rather than captions:
///
/// - **stilling** — *"a wait, not a prompt; there is no override."*
/// - **settling** — *"never fire early."*
/// - **swapping** — *"hold the pose."*
///
/// The write unit and the abort unit are the same thing, which is why nothing
/// partial ever needs interpreting: frames and the station record are buffered
/// in memory and land together at close, so a station either completed or never
/// existed.
enum StationPhase: String, Codable, CaseIterable {
    case noSession
    case sessionOpen
    case stationOpen
    case swapping
    case stilling
    case settling
    case capturing

    var title: String {
        switch self {
        case .noSession:   return "No session"
        case .sessionOpen: return "Session open"
        case .stationOpen: return "At the station"
        case .swapping:    return "Swapping sensor"
        case .stilling:    return "Waiting for still"
        case .settling:    return "Settling exposure"
        case .capturing:   return "Capturing"
        }
    }

    /// Verbatim from the prototype — these are the sentences that explain why
    /// the operator is being made to wait.
    var note: String {
        switch self {
        case .noSession:
            return "Nothing open. Declaring a station requires a session."
        case .sessionOpen:
            return "A session is open with no station. This is where you walk to the next pose."
        case .stationOpen:
            return "Standing at the pose. The next capture set can begin."
        case .swapping:
            return "Reconfiguring the capture session for a different sensor. Hold the pose."
        case .stilling:
            return "Waiting for the device to be still. A wait, not a prompt — there is no override."
        case .settling:
            return "Waiting for the requested exposure to actually take effect. Never fire early."
        case .capturing:
            return "Ready to fire the next frame of this set."
        }
    }

    /// True while a station is in flight and a fault would abort it.
    var isInStation: Bool {
        switch self {
        case .stationOpen, .swapping, .stilling, .settling, .capturing: return true
        default: return false
        }
    }
}

/// What ended a station short. All five remain hard faults; motion was demoted
/// to an advisory and is deliberately absent (#10, as amended).
enum StationFault: String, Codable {
    case storageExhausted
    case thermal
    case captureError
    case batteryDeath
    case uncappedFrameInDarkRun

    var operatorNote: String {
        switch self {
        case .storageExhausted:      return "storage exhausted"
        case .thermal:               return "thermal limit"
        case .captureError:          return "capture API error"
        case .batteryDeath:          return "battery death"
        case .uncappedFrameInDarkRun: return "an uncapped frame in a dark run"
        }
    }
}

/// A station's shot list and where the cursor has reached.
///
/// `canClose` is only true once the cursor has passed the end: a station is
/// complete when its whole shot list is, and there is no partial-completion
/// state to record because there is no way to leave one.
struct ShotList: Equatable {
    var entries: [ShotListEntry] = []
    var cursor: Int = 0

    var current: ShotListEntry? { cursor < entries.count ? entries[cursor] : nil }
    var remaining: Int { max(0, entries.count - cursor) }
    var canClose: Bool { !entries.isEmpty && cursor >= entries.count }
    var totalFrames: Int { entries.reduce(0) { $0 + $1.frameCount } }

    /// Group by sensor, which is the default (#8), preserving the order each
    /// sensor first appears so an authored sequence still shows through.
    static func grouped(_ entries: [ShotListEntry]) -> [ShotListEntry] {
        var order: [SensorCapability.Sensor] = []
        for e in entries where !order.contains(e.sensor) { order.append(e.sensor) }
        var out: [ShotListEntry] = []
        for sensor in order {
            for e in entries where e.sensor == sensor { out.append(e) }
        }
        return out.enumerated().map {
            ShotListEntry(index: $0.offset, sensor: $0.element.sensor, captureSet: $0.element.captureSet)
        }
    }

    static func authored(_ entries: [ShotListEntry]) -> [ShotListEntry] {
        entries.enumerated().map {
            ShotListEntry(index: $0.offset, sensor: $0.element.sensor, captureSet: $0.element.captureSet)
        }
    }
}

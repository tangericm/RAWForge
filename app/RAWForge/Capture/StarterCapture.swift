import Foundation

/// A short path into the ordinary protocol system.
///
/// These are templates, not a second capture mode. `captureSet` returns the
/// same named, versioned recipe the editor would produce; the protocol library
/// assigns its first persisted version before it enters the shot list.
enum StarterCapture: String, CaseIterable, Identifiable {
    case exposureLadder
    case repeat16
    case single

    var id: String { rawValue }

    var allowedFiringModes: [ExecutionMode] {
        self == .single ? [.hardwareBracket] : [.hardwareBracket, .sequential]
    }

    var defaultFiringMode: ExecutionMode { .hardwareBracket }

    func captureSet(firing requested: ExecutionMode) -> CaptureSet {
        let firing = allowedFiringModes.contains(requested) ? requested : defaultFiringMode
        let base = CaptureSpec(shutterSeconds: 1.0 / 125, iso: 100)
        var set: CaptureSet

        switch self {
        case .exposureLadder:
            set = .shutterSweep(base: base, stopsPerRung: 1, rungs: 7,
                                name: "Exposure Ladder · \(firing.label)", version: 0)
        case .repeat16:
            set = .repeated(base, count: 16,
                            name: "Repeat 16 · \(firing.label)", version: 0)
        case .single:
            set = .repeated(base, count: 1, name: "Single Frame", version: 0)
        }

        set.executionMode = firing
        return set
    }
}

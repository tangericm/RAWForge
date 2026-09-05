import AVFoundation
import Foundation

/// App composition and the non-scene bench state.
///
/// Station lifecycle belongs to `StationController`; this object wires its
/// live adapters to the camera and retains only the app-wide probe, protocol
/// library and instrument-bench concerns.
@MainActor
final class CaptureModel: ObservableObject {
    let rig: CaptureRig
    let motionRecorder: MotionRecorder
    let health: DeviceHealth
    private let liveStationCapture: LiveStationCapture
    let station: StationController
    let workflow: RecipeCoordinator

    init() {
        let rig = CaptureRig()
        let motion = MotionRecorder()
        let health = DeviceHealth()
        let adapter = LiveStationCapture(rig: rig, motion: motion)
        let station = StationController(capture: adapter, persistence: LiveStationPersistence(), motion: motion, health: health)
        self.rig = rig
        self.motionRecorder = motion
        self.health = health
        self.liveStationCapture = adapter
        self.station = station
        self.workflow = RecipeCoordinator(station: station)
    }

    /// App-wide screens still consume these values through the composition
    /// root; their source of truth is the station controller.
    var report: CapabilityReport? {
        get { station.report }
        set { objectWillChange.send(); station.report = newValue }
    }
    var session: SessionRecord? {
        get { station.session }
        set { objectWillChange.send(); station.session = newValue }
    }
    var status: String {
        get { station.status }
        set { objectWillChange.send(); station.status = newValue }
    }
    var busy: Bool {
        get { station.busy }
        set { objectWillChange.send(); station.busy = newValue }
    }
    var progress: String { station.progress }
    @Published private(set) var cameraDenied = false
    @Published var selectedProtocol: CaptureSet?
    @Published var savedProtocols: [CaptureSet] = []
    @Published var evOffsets: [String: Double] = [:]
    @Published var selectedSensors: Set<SensorCapability.Sensor> = [.wide]

    static let poseIntentPresets = [
        "tripod-rigid", "tripod-soft", "handheld",
        "dark-frame", "calibration",
    ]

    lazy var bench = BenchModel(rig: rig, motionRecorder: motionRecorder)

    func capability(_ sensor: SensorCapability.Sensor) -> SensorCapability? {
        report?.sensors.first { $0.sensor == sensor }
    }

    var orderedSensors: [SensorCapability.Sensor] {
        SensorCapability.Sensor.allCases.filter { selectedSensors.contains($0) }
    }

    var currentSet: CaptureSet? {
        guard let protocolSet = selectedProtocol else { return nil }
        return CaptureSet(
            name: protocolSet.name,
            version: protocolSet.version,
            specs: protocolSet.specs,
            generator: protocolSet.generator,
            perSensorEVOffsetStops: evOffsets)
    }

    func refreshProtocols() {
        savedProtocols = ProtocolLibrary.all()
        if let name = selectedProtocol?.name {
            selectedProtocol = ProtocolLibrary.load(named: name)
        }
    }

    /// App-wide entry points used by boot and the debug bench. Station-focused
    /// screens call and observe `station` directly.
    func openSession() {
        objectWillChange.send()
        station.openSession()
    }

    func restoreShotList() { station.restoreShotList() }
    func startFraming() { station.startFraming() }

    // MARK: - Probe

    func probe() async {
        guard await requestCamera() else {
            cameraDenied = true
            status = "camera permission denied — no sensor can be probed"
            logError(.app, "camera permission denied — no sensor can be probed")
            return
        }
        status = "probing sensors…"
        let result = await Task.detached(priority: .userInitiated) {
            CapabilityProbe.run()
        }.value
        report = result
        if let first = result.usableSensors.first { selectedSensors = [first.sensor] }
        status = result.canCapture
            ? "\(result.usableSensors.count) of \(result.sensors.count) sensors deliver Bayer"
            : "no sensor on this device delivers Bayer RAW — capture refused"
        logInfo(.probe, "probed \(result.sensors.count) sensor(s), "
                + "\(result.usableSensors.count) deliver Bayer")
        for sensor in result.sensors {
            if sensor.isUsable {
                logInfo(.probe, "\(sensor.sensor.rawValue) usable · "
                        + "\(sensor.bayerFormatFourCC ?? "?") · bracket max "
                        + "\(sensor.maxBracketedCapturePhotoCount)")
            } else {
                logWarn(.probe, "\(sensor.sensor.rawValue) unusable — "
                        + "\(sensor.exclusionReason ?? "no reason given")")
            }
        }
    }

    // MARK: - Bench runs

    func runDarkCalibration() async {
        guard let report, report.canCapture else {
            status = "no usable sensor"
            return
        }
        let sensors = orderedSensors.filter { capability($0)?.isUsable == true }
        guard let set = currentSet else {
            status = "choose a protocol before running a calibration"
            return
        }
        busy = true
        defer { busy = false }
        let outcome = await bench.runDarkCalibration(BenchModel.DarkRequest(
            report: report, sensors: sensors, set: set, repeats: bench.darkRepeats))
        // Calibration owns a separate session. Its outcome must not replace
        // the scene Run retained by StationController and its active bookmark.
        status = outcome.status
    }

    #if DEBUG
    func runWhiteBalanceProbe() async {
        guard let session else { status = "open a session first"; return }
        guard let sensor = orderedSensors.first,
              let capability = capability(sensor), capability.isUsable else {
            status = "no usable sensor selected"
            return
        }
        guard let set = currentSet else {
            status = "choose a protocol before running this check"
            return
        }
        busy = true
        defer { busy = false }
        let stationIndex = station.reserveStationIndex()
        let outcome = await bench.runWhiteBalanceProbe(BenchModel.WhiteBalanceRequest(
            session: session,
            sensor: sensor,
            capability: capability,
            set: set,
            stationIndex: stationIndex,
            poseIntent: station.poseIntent,
            run: { specs, sensor, wb, session, station, bracketIndex, firing, timebase in
                try await self.liveStationCapture.capture(StationCaptureRequest(
                    specs: specs,
                    sensor: sensor,
                    whiteBalance: StationWhiteBalance(set: wb.set, readBack: wb.readBack),
                    session: session,
                    stationIndex: station,
                    bracketIndex: bracketIndex,
                    firing: firing,
                    focus: nil,
                    minimumGap: 0,
                    timebase: timebase), progress: { _ in })
            }))
        if let record = outcome.station { station.lastStation = record }
        status = outcome.status
    }

    func runZoomProbe() async {
        guard let session else { status = "open a session first"; return }
        guard let sensor = orderedSensors.first else {
            status = "no sensor selected"
            return
        }
        busy = true
        defer { busy = false }
        status = await bench.runZoomProbe(session: session, sensor: sensor).status
    }
    #endif

    private func requestCamera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) {
                    continuation.resume(returning: $0)
                }
            }
        default:
            return false
        }
    }
}

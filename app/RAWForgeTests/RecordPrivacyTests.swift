import Foundation
import XCTest
@testable import RAWForge

final class RecordPrivacyTests: XCTestCase {
    func testCurrentSessionOmitsBootAnchorAndStationNamesItsSegment() throws {
        let session = SessionRecord.fixture()
        let sessionText = String(
            decoding: try JSONEncoder.rawforge.encode(session),
            as: UTF8.self)
        let station = StationRecord.fixture(captureSegmentID: "segment-1")
        let stationText = String(
            decoding: try JSONEncoder.rawforge.encode(station),
            as: UTF8.self)

        XCTAssertFalse(sessionText.contains("openedAtUptime"))
        XCTAssertTrue(stationText.contains(CaptureTimebase.persistedName))
        XCTAssertTrue(stationText.contains("segment-1"))
    }

    func testCurrentFrameEncodingContainsOnlyRelativeMonotonicKeys() throws {
        let frame = FrameRecord.fixture(capturedAtSegmentStartSeconds: 2.5)
        let text = String(decoding: try JSONEncoder.rawforge.encode(frame), as: UTF8.self)

        XCTAssertTrue(text.contains("capturedAtSegmentStartSeconds"))
        XCTAssertFalse(text.contains("capturedAtUptime"))
        XCTAssertFalse(text.contains("uptimeAtDelivery"))
        XCTAssertFalse(text.contains("latestMotionTimestamp"))
    }

    func testCurrentMotionSampleNamesItsRelativeDomain() throws {
        let sample = MotionSample(
            secondsSinceSegmentStart: 1.25,
            gx: 1, gy: 2, gz: 3,
            ax: 4, ay: 5, az: 6)
        let text = String(decoding: try JSONEncoder.rawforge.encode(sample), as: UTF8.self)

        XCTAssertTrue(text.contains("secondsSinceSegmentStart"))
        XCTAssertFalse(text.contains(#""t""#))
    }

    func testCurrentRecordDecodersRejectNoncurrentDeclaredSchemas() throws {
        let session = try JSONEncoder.rawforge.encode(SessionRecord.fixture())
        let station = try JSONEncoder.rawforge.encode(
            StationRecord.fixture(captureSegmentID: "segment-1"))

        for schema in [4, 999] {
            let data = try replacingSchema(in: session, with: schema)
            XCTAssertThrowsError(try JSONDecoder.rawforge.decode(SessionRecord.self, from: data))
        }
        for schema in [2, 999] {
            let data = try replacingSchema(in: station, with: schema)
            XCTAssertThrowsError(try JSONDecoder.rawforge.decode(StationRecord.self, from: data))
        }
    }

    private func replacingSchema(in data: Data, with schema: Int) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = schema
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private extension JSONEncoder {
    static var rawforge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var rawforge: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension SessionRecord {
    static func fixture() -> SessionRecord {
        SessionRecord(
            sessionId: "session-1",
            openedAt: Date(timeIntervalSince1970: 1_000),
            capability: CapabilityReport(device: .current(), sensors: []),
            availableCapacityBytes: 1_000_000)
    }
}

private extension StationRecord {
    static func fixture(captureSegmentID: String) -> StationRecord {
        StationRecord(
            stationIndex: 1,
            sessionId: "session-1",
            openedAt: Date(timeIntervalSince1970: 1_000),
            closedAt: Date(timeIntervalSince1970: 1_001),
            brackets: [],
            captureTimebase: CaptureTimebase(
                segmentID: captureSegmentID,
                originUptime: 987_654))
    }
}

private extension FrameRecord {
    static func fixture(capturedAtSegmentStartSeconds: TimeInterval) -> FrameRecord {
        FrameRecord(
            frameIndex: 1,
            filename: "frame.dng",
            sensor: "1x",
            requested: Exposure(shutterSeconds: 0.01, iso: 100, whiteBalanceGains: nil),
            deviceAchieved: nil,
            photoAchieved: nil,
            dng: DNGWitness.fixture,
            focus: nil,
            zoomFactor: 1,
            capturedAtSegmentStartSeconds: capturedAtSegmentStartSeconds,
            capturedAt: Date(timeIntervalSince1970: 1_000),
            photoTimestampSeconds: nil,
            gapFromPreviousSeconds: nil,
            clipping: nil,
            motion: nil,
            motionNeighbourhood: nil,
            deliveredAtSegmentStartSeconds: 2.6,
            latestMotionAtSegmentStartSeconds: 2.55)
    }
}

private extension FrameRecord.DNGWitness {
    static let fixture = FrameRecord.DNGWitness(
        exposureTimeSeconds: nil,
        iso: nil,
        asShotNeutral: nil,
        blackLevel: nil,
        whiteLevel: nil,
        cfaPattern: nil,
        activeArea: nil,
        uniqueCameraModel: nil,
        localizedCameraModel: nil,
        noiseReductionAppliedCoerced: nil,
        noiseReductionApplied: nil,
        noiseProfile: nil,
        dateTimeOriginal: nil,
        subsecTimeOriginal: nil,
        storedImageWidth: nil,
        imageWidth: nil,
        imageHeight: nil)
}

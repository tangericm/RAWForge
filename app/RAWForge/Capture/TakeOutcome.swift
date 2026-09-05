import Foundation

enum TakeOutcome: Equatable {
    case completed(correlationID: UUID, station: StationRecord)
    case cancelled(correlationID: UUID)
    case blocked(message: String)
    case failed(correlationID: UUID, message: String)
}

enum CaptureInterruption: Error { case stopRequested }

/// Preparation may suspend while the operator requests Stop. Check again at
/// the last safe boundary before issuing a camera request, but never discard
/// its returned response before the caller has banked it.
enum CaptureRequestBoundary {
    static func perform<T>(shouldStop: @MainActor () -> Bool,
                           wait: () async throws -> Void,
                           capture: () async throws -> T) async throws -> T {
        if await shouldStop() { throw CaptureInterruption.stopRequested }
        try await wait()
        if await shouldStop() { throw CaptureInterruption.stopRequested }
        return try await capture()
    }
}

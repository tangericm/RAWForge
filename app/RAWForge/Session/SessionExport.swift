import Foundation

/// Packages a session directory for transfer.
///
/// #11 settles transfer as `UIFileSharingEnabled` plus
/// `LSSupportsOpeningDocumentsInPlace` — the folder appears in Files and over a
/// cable, and a session moves by dragging one folder out. That still works and
/// remains the primary route.
///
/// This adds the in-app path, because AirDropping a *folder* out of Files is
/// awkward and a session is a folder by design. The archive is produced by
/// `NSFileCoordinator` with the `.forUploading` reading intent — the system's
/// own zip, with no third-party dependency and no hand-rolled archive format
/// to get wrong.
///
/// The session directory is never modified: the zip is built into a temporary
/// location and handed to the share sheet from there.
enum SessionExport {

    enum ExportError: LocalizedError {
        case coordinationFailed(String)
        case noSuchSession(String)

        var errorDescription: String? {
            switch self {
            case .coordinationFailed(let s): return "Could not package the session: \(s)"
            case .noSuchSession(let s):      return "No session directory named \(s)"
            }
        }
    }

    /// Returns a `.zip` in a temporary directory, ready for a share sheet.
    /// The caller owns it; iOS clears the temporary directory on its own terms.
    static func archive(sessionId: String) throws -> URL {
        let source = SessionStore.directory(for: sessionId)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ExportError.noSuchSession(sessionId)
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sessionId).zip")
        try? FileManager.default.removeItem(at: destination)

        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: source, options: [.forUploading], error: &coordinatorError
        ) { zipped in
            // The coordinated URL is only valid inside this block, so the
            // archive is copied out before it goes away.
            do { try FileManager.default.copyItem(at: zipped, to: destination) }
            catch { copyError = error }
        }
        if let e = coordinatorError { throw ExportError.coordinationFailed(e.localizedDescription) }
        if let e = copyError { throw ExportError.coordinationFailed(e.localizedDescription) }
        return destination
    }

    static func formatTotal(_ sessionIds: [String]) -> String {
        SessionEstimate.formatBytes(sessionIds.reduce(Int64(0)) { $0 + sizeOnDisk(sessionId: $1) })
    }

    /// Bytes on disk, so the operator knows what they are about to send before
    /// they send it — a three-sensor scene runs to ~2 GB (#11).
    static func sizeOnDisk(sessionId: String) -> Int64 {
        let dir = SessionStore.directory(for: sessionId)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(Int64(0)) {
            $0 + Int64(((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0)
        }
    }
}

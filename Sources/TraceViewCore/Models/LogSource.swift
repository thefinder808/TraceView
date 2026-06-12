import Foundation

enum LogSource {
    case file(URL)
    case unifiedLog(predicate: String?)
    case stdin
    /// k-way merge of N existing open documents, sorted by timestamp.
    /// Loaded by LogDocument by subscribing to each source's didAppend
    /// and re-emitting the merged stream. Holds doc IDs (not refs) so
    /// AppState remains the single source of truth for document lookup.
    case merged(sourceIDs: [UUID])
    /// A live remote log stream (v1: SSH tail). Carries the saved connection
    /// so LogDocument can (re)build the transport. See RemoteLogStream.
    case remote(RemoteConnection)
}

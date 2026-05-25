import Foundation

/// Coarse-grained tag identifying which parser owns a given file.
///
/// Used by Phase 4's indexed-mode build pass to pick the right byte-level
/// level + timestamp scanner without re-running `canParse` or string-
/// matching parser names. The four cases mirror the three line-stateless
/// parsers eligible for indexed mode (PlainText, SCCM, CSV) plus an
/// `.other` catch-all for everything else (IPS, Diag, UnifiedLog, JSON,
/// future formats). Indexed mode short-circuits to in-memory loading for
/// `.other` upstream of `LogIndex.build`, so PR1's scanners never see it
/// in practice — the enum value exists so the API is total.
enum ParserKind {
    case plainText
    case sccm
    case csv
    case other
}

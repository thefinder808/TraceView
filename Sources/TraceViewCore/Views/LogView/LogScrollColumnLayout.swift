import Foundation
import CoreGraphics

/// Identifies a column in the custom log view. Raw values match the
/// identifiers used by NSLogTableView so saved widths and order from
/// `ColumnLayoutStore` round-trip across the two renderers during the
/// feature-flag period.
enum ColumnID: String, CaseIterable {
    case lineNumber
    case timestamp
    case level
    case component
    case sourceLabel
    case message

    /// Initial width when no saved width is present. Mirrors the
    /// NSTableColumn defaults at NSLogTableView.swift:96-138.
    var defaultWidth: CGFloat {
        switch self {
        case .lineNumber:  return 48
        case .timestamp:   return 110
        case .level:       return 52
        case .component:   return 110
        case .sourceLabel: return 130
        case .message:     return 200
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .lineNumber:  return 48
        case .timestamp:   return 80
        case .level:       return 40
        case .component:   return 60
        case .sourceLabel: return 80
        case .message:     return 200
        }
    }

    /// `nil` for the autoresizing column (message). Every other column has
    /// a hard upper bound so a stray drag can't swallow the message column.
    var maxWidth: CGFloat? {
        switch self {
        case .lineNumber:  return 80
        case .timestamp:   return 280
        case .level:       return 80
        case .component:   return 320
        case .sourceLabel: return 240
        case .message:     return nil
        }
    }

    /// Title rendered by the column header. Matches the titles used by
    /// the NSTableColumn defaults in NSLogTableView (e.g. "#" for the
    /// line-number gutter) so users see the same labels regardless of
    /// which renderer is active.
    var title: String {
        switch self {
        case .lineNumber:  return "#"
        case .timestamp:   return "Timestamp"
        case .level:       return "Level"
        case .component:   return "Component"
        case .sourceLabel: return "Source"
        case .message:     return "Message"
        }
    }
}

/// Computed frame of a single column in the layout. `x` is the column's
/// left edge in document-view coordinates; `width` is its rendered width.
struct ColumnFrame: Equatable {
    let id: ColumnID
    let x: CGFloat
    let width: CGFloat
}

/// Which columns are currently rendered. `.level` and `.message` are
/// always visible, so they don't appear as toggleable fields here. The
/// three user toggles (line number, timestamp, component) and the
/// document-driven source column are the only configurable ones.
struct ColumnVisibility: Equatable {
    var showLineNumber: Bool
    var showTimestamp: Bool
    var showComponent: Bool
    var showSource: Bool

    func isVisible(_ id: ColumnID) -> Bool {
        switch id {
        case .lineNumber:  return showLineNumber
        case .timestamp:   return showTimestamp
        case .level:       return true
        case .component:   return showComponent
        case .sourceLabel: return showSource
        case .message:     return true
        }
    }
}

/// Pure-value layout computation for the custom log view's columns.
/// Splitting this out from `LogScrollDocumentView` keeps the geometry math
/// unit-testable without spinning up an `NSView`. P2.2 (column resize +
/// reorder + persistence) wires `savedWidths` and `order` through; PR #1
/// always passes nil and gets the defaults.
enum LogScrollColumnLayout {
    /// Default left-to-right column order: line number, timestamp, level,
    /// component, source, message. Source appears between component and
    /// message because that matches the natural read order on merged-view
    /// rows (timestamp · level · component · source · message).
    static let defaultOrder: [ColumnID] = [
        .lineNumber, .timestamp, .level, .component, .sourceLabel, .message
    ]

    /// Build `[ColumnFrame]` for the visible columns at the given bounds
    /// width. The `.message` column always fills the remainder; if the
    /// remainder would fall below its `minWidth`, message gets exactly its
    /// minWidth and the layout overflows past `boundsWidth` (caller's
    /// `NSScrollView` clips). Saved widths are clamped to each column's
    /// `[minWidth, maxWidth]` band. Unlisted IDs in `order` fall in at the
    /// end using `defaultOrder`'s positions.
    static func compute(
        boundsWidth: CGFloat,
        visibility: ColumnVisibility,
        savedWidths: [ColumnID: CGFloat] = [:],
        order: [ColumnID]? = nil
    ) -> [ColumnFrame] {
        let resolvedOrder = resolve(order: order)
        let visibleIDs = resolvedOrder.filter { visibility.isVisible($0) }

        var widths: [ColumnID: CGFloat] = [:]
        var nonMessageTotal: CGFloat = 0
        for id in visibleIDs where id != .message {
            let raw = savedWidths[id] ?? id.defaultWidth
            let clamped: CGFloat
            if let maxW = id.maxWidth {
                clamped = max(id.minWidth, min(maxW, raw))
            } else {
                clamped = max(id.minWidth, raw)
            }
            widths[id] = clamped
            nonMessageTotal += clamped
        }

        if visibility.isVisible(.message) {
            let remainder = boundsWidth - nonMessageTotal
            widths[.message] = max(ColumnID.message.minWidth, remainder)
        }

        var frames: [ColumnFrame] = []
        var x: CGFloat = 0
        for id in visibleIDs {
            let w = widths[id] ?? 0
            frames.append(ColumnFrame(id: id, x: x, width: w))
            x += w
        }
        return frames
    }

    private static func resolve(order: [ColumnID]?) -> [ColumnID] {
        guard let order else { return defaultOrder }
        let seen = Set(order)
        let missing = defaultOrder.filter { !seen.contains($0) }
        return order + missing
    }
}

# TraceView - Specification

A native macOS log viewer inspired by Microsoft CMTrace. Built with SwiftUI, targeting macOS 14+.

## Overview

TraceView brings the best of CMTrace to macOS: real-time log following, error/warning highlighting, and built-in error code lookup — all in a native, theme-aware interface. It handles plain text logs, macOS unified system logs, JSON structured logs, and even SCCM-format logs for cross-platform admins.

---

## Core Features

### 1. Real-Time Log Following

The defining CMTrace behavior: when you're viewing the bottom of a log, new lines auto-scroll into view. Scroll up to investigate, and following pauses automatically. Scroll back to the bottom (or click "Jump to Bottom") and it resumes.

**Implementation:**
- File watching via `DispatchSource.makeFileSystemObjectSource` (kernel-level notifications, no polling)
- Incremental reading from last known file offset — never re-reads the whole file
- Bottom-of-scroll detection via an invisible anchor view (`onAppear`/`onDisappear`)
- Visual indicator: green pulsing "Following" badge or gray "Paused" badge in the status bar
- Floating "Jump to Bottom" button appears when scrolled up
- Handles log rotation (file rename/delete detection, re-open at new path)

**Live system log streaming:**
- Wraps `log stream --style json` via `Process` for real-time unified log capture
- Configurable predicate filtering (e.g., subsystem, process, category)

### 2. Error/Warning Highlighting

Errors get red row backgrounds, warnings get yellow — instantly visible when scrolling through thousands of lines.

**Detection (two-tier):**

*Tier 1 — Structured:* Parsers that understand the log format (unified log `messageType`, JSON `level` field, SCCM `type` field) set `LogLevel` directly from the data.

*Tier 2 — Keyword heuristic:* For plain text logs, scan the message for patterns:
- **Error**: `error`, `failed`, `failure`, `fatal`, `crash`, `panic`, `abort`, `exception`, `critical`, `severe`
- **Warning**: `warn`, `warning`, `caution`, `deprecated`, `retrying`, `timeout`

**Display:**
- Error rows: red-tinted background (`~0.15` opacity)
- Warning rows: yellow-tinted background (`~0.12` opacity)
- Critical rows: deeper red tint
- Debug rows: dimmed text
- All colors are theme-aware

**Navigation:**
- `Cmd+E`: Jump to next error
- `Cmd+Shift+E`: Jump to previous error

### 3. Error Code Lookup

Built-in database for decoding macOS error codes — no more Googling `0xE00002BC`.

**Supported error domains:**
| Domain | Count | Examples |
|--------|-------|---------|
| errno (POSIX) | ~106 | `ENOENT` (2), `EPERM` (1), `EACCES` (13) |
| OSStatus | ~200 | `fnfErr` (-43), `paramErr` (-50), Security framework codes |
| IOReturn | ~50 | `kIOReturnNotReady` (0xE00002BC), `kIOReturnNoDevice` (0xE00002C0) |
| Mach (kern_return_t) | ~52 | `KERN_INVALID_ADDRESS` (1), `KERN_NO_SPACE` (3) |
| HTTP Status | ~60 | 404 Not Found, 500 Internal Server Error |

**Input formats:** Decimal (`-43`), hex (`0xE00002BC`), symbolic (`ENOENT`), or auto-detect.

**UI:**
- Inspector panel slides in from the right (HSplitView)
- Text field for manual lookup with domain selector
- Results show: domain badge, symbolic name, decimal/hex value, description
- Recent lookups history (last 20, persisted)

**Inline detection:**
- Error codes in log lines are detected via regex and rendered as tappable links
- Clicking opens the lookup panel with the decoded result

### 4. Log Parsing (Pluggable)

**Parser protocol:**
```
LogParser
  name: String
  supportedExtensions: Set<String>
  canParse(sampleLines: [String]) -> Double   // confidence 0.0–1.0
  parse(line: String, lineNumber: Int, entryID: Int) -> LogEntry
```

**Built-in parsers:**
| Parser | Format | Detection |
|--------|--------|-----------|
| PlainTextParser | Syslog, generic timestamped text, bare text | Fallback — always matches |
| UnifiedLogParser | JSON from `log show --style json` / `log stream --style json` | JSON array with `messageType` field |
| JSONLogParser | Structured JSON (one object per line) | Lines start with `{`, contain `level`/`message` keys |
| CSVLogParser | CSV with headers | First line is comma-separated headers |
| SCCMLogParser | `<![LOG[...]LOG]!><time="..." ...>` | SCCM log format markers |

**Auto-detection:** `ParserRegistry` reads the first ~50 lines, scores each parser's confidence, and picks the best match. User can override in the sidebar context menu.

### 5. Search & Filtering

**Filter bar** (above log table):
- Text search field with regex toggle
- Case sensitivity toggle
- Log level filter chips (toggleable pills per level, colored by severity)
- Component/process filter dropdown (populated from parsed entries)
- Date range filter
- Match count badge: "42 of 45,231 lines"
- Clear filters button

**Performance:**
- Filtering runs off main thread via Swift structured concurrency
- 150ms debounce on keystroke
- New incoming lines are tested incrementally (no full re-filter)

---

## Data Model

### LogEntry
```
id: Int                  // Sequential (not UUID — performance)
lineNumber: Int          // 1-based original line number
timestamp: Date?         // Parsed timestamp, nil if unparseable
level: LogLevel          // Detected severity
message: String          // Display text
component: String?       // Process/component name
threadID: String?        // Thread ID if available
source: String?          // Source file/function
rawLine: String          // Original unparsed text
```

### LogLevel
```
debug, info, notice, warning, error, critical, unknown
```
Comparable by severity. Each has a display name and SF Symbol icon.

### LogDocument
```
id: UUID
source: LogSource        // .file(URL), .unifiedLog(predicate), .stdin
displayName: String
entries: [LogEntry]
isFollowing: Bool
isLive: Bool
fileSize: UInt64
encoding: String.Encoding
lastReadOffset: UInt64   // For incremental reading
parser: LogParser
```

### LogFilter
```
searchText: String
isRegex: Bool
caseSensitive: Bool
minimumLevel: LogLevel
enabledLevels: Set<LogLevel>
component: String?
dateRange: ClosedRange<Date>?
```

### ErrorCodeInfo
```
domain: ErrorDomain
code: Int32
symbolicName: String     // e.g., "ENOENT"
description: String      // "No such file or directory"
hexValue: String?        // "0x2"
```

---

## UI Layout

### Main Window
```
+------------------------------------------+
| Toolbar: [Open] [Stream] [Filter] [Find] |
+-------+----------------------------------+
|       | Filter Bar                       |
| Side  | [Search____] [.*] [Levels chips] |
| bar   +----------------------------------+
|       |                                  |
| Open  | Log Table                        |
| files | #   Time   Level  Component Msg  |
| list  | 1   10:01  INFO   kernel    ...  |
|       | 2   10:01  WARN   launchd   ...  |
|       | 3   10:02  ERROR  WindowSvr ...  |
|       |                                  |
|       +----------------------------------+
|       | Status: 45,231 lines | UTF-8     |
|       | [Following *]       [Jump to End]|
+-------+----------------------------------+
```

### With Error Lookup Panel Open
```
+-------+--------------------+-------------+
| Side  | Log Table          | Error       |
| bar   |                    | Lookup      |
|       |                    | [0xE000...] |
|       |                    | IOReturn    |
|       |                    | kIOReturn   |
|       |                    | NotReady    |
+-------+--------------------+-------------+
```

### Sidebar
- Section "Open Files": filename, line count badge, live/static indicator
- Section "System Logs": quick-access unified log streams (All, Kernel, User, custom predicate)
- Bottom: Settings button
- Context menu: Close, Reveal in Finder, Copy Path, Reload, Change Parser

### Log Table
- Columns: Line number | Timestamp | Level (badge) | Component | Message
- Column visibility and widths configurable, persisted
- Monospaced font for message text
- Fixed row height for virtual scroll performance
- Click to select, Cmd+Click for multi-select
- Right-click context menu: Copy Line, Copy Message, Lookup Error Code, Filter to Component

### Status Bar
- Total line count / filtered count
- File encoding
- Following indicator (green pulse / gray paused)
- File size

---

## Theme System

Reuses MacPerf's `AppTheme` protocol pattern with log-specific additions.

**Theme options:** System (auto), Dark, Light, Neon

**AppTheme protocol properties:**
- Standard: `windowBackground`, `sidebarBackground`, `cardBackground`, `primaryText`, `secondaryText`, `tertiaryText`, `sidebarHover`, `sidebarActive`, `tableRowHover`, `border`, `trackBackground`
- Log-specific: `errorHighlight`, `warningHighlight`, `criticalHighlight`, `errorText`, `warningText`, `debugText`, `infoText`, `timestampColor`, `lineNumberColor`, `searchHighlight`, `followingIndicator`, `accentColor`
- Effects: `glowEnabled`, `cardShadow`

**ThemeManager:** Same pattern as MacPerf — `ObservableObject` with `@Published` selection, persisted to UserDefaults (`traceview.theme`), listens to system appearance changes.

---

## Keyboard Shortcuts

### File
| Shortcut | Action |
|----------|--------|
| `Cmd+O` | Open log file |
| `Cmd+Shift+U` | Stream unified system log |
| `Cmd+W` | Close current tab |

### Navigate
| Shortcut | Action |
|----------|--------|
| `Cmd+K` | Command palette |
| `Cmd+G` | Jump to line |
| `Cmd+End` | Jump to bottom |
| `Cmd+Shift+F` | Toggle following |
| `Cmd+E` | Next error |
| `Cmd+Shift+E` | Previous error |
| `Cmd+1–9` | Switch tabs |

### Filter
| Shortcut | Action |
|----------|--------|
| `Cmd+F` | Focus search |
| `Cmd+Opt+R` | Toggle regex |
| `Cmd+Delete` | Clear filters |
| `Cmd+Opt+E` | Show only errors |
| `Cmd+Opt+W` | Show errors & warnings |

### Tools
| Shortcut | Action |
|----------|--------|
| `Cmd+Shift+L` | Error code lookup |
| `Cmd+R` | Reload file |
| `Cmd+Shift+S` | Export filtered log |
| `Cmd+T` | Cycle theme |

---

## Performance Targets

| Scenario | Target |
|----------|--------|
| Open 100K-line file | < 2 seconds to first render |
| Scroll through 100K lines | 60 fps, no hitching |
| Live tail at 100 lines/sec | Smooth follow, no lag |
| Filter 100K lines | < 500ms to show results |
| Open 1M-line file | < 5 seconds, sliding window for memory |
| Memory (100K lines loaded) | < 150 MB |

**Strategies:**
- `LazyVStack` with fixed row height (no dynamic sizing)
- `Int` IDs on `LogEntry` (not `UUID`)
- Incremental file reads (never re-read whole file)
- Async filtering with cancellation on new input
- Memory-mapped file reading (`Data(contentsOf:options:.mappedIfSafe)`)
- Sliding window for 1M+ line files (keep ~50K parsed entries in memory)

---

## Project Structure

```
TraceView/
  Package.swift                          # swift-tools-version: 5.9, macOS 14+
  Sources/TraceView/
    App/
      TraceViewApp.swift                 # @main, Scene, .commands, EnvironmentObject injection
      AppState.swift                     # Central state: open documents, selection, UI flags
      SettingsManager.swift              # UserDefaults persistence (didSet auto-save)
      WindowAccessor.swift               # NSViewRepresentable for window config
    Models/
      LogEntry.swift
      LogLevel.swift
      LogSource.swift
      LogDocument.swift
      LogFilter.swift
      ErrorCodeInfo.swift
      ErrorDomain.swift
    Parsing/
      LogParser.swift                    # Protocol
      PlainTextParser.swift
      UnifiedLogParser.swift
      JSONLogParser.swift
      CSVLogParser.swift
      SCCMLogParser.swift
      ParserRegistry.swift               # Auto-detection
      LevelDetector.swift                # Keyword heuristic for plain text
    Services/
      FileWatcher.swift                  # DispatchSource file monitoring
      UnifiedLogStream.swift             # Process wrapper for `log stream`
      ErrorCodeLookup.swift              # Error code database + lookup
      LogSearchEngine.swift              # Regex/text search
      ExportService.swift                # Export filtered log
    ViewModels/
      LogDocumentViewModel.swift         # Entries, filtering, follow state
      ErrorLookupViewModel.swift         # Lookup panel state
      SidebarViewModel.swift             # Open documents management
    Theme/
      AppTheme.swift                     # Protocol with log-specific colors
      ThemeManager.swift                 # Persisted theme selection
      Themes/
        DarkTheme.swift
        LightTheme.swift
        NeonTheme.swift
    Views/
      ContentView.swift                  # NavigationSplitView shell
      WelcomeView.swift                  # Empty state with drag-drop
      SettingsView.swift                 # Theme, font size, highlight rules
      Sidebar/
        SidebarView.swift
        SidebarDocumentRow.swift
      LogView/
        LogTableView.swift               # Main log display (virtual scroll)
        LogRowView.swift                 # Single row with highlighting
        FilterBarView.swift              # Search + level chips + filters
        FollowIndicator.swift            # Following/Paused badge
      ErrorLookup/
        ErrorLookupPanel.swift           # Inspector panel
        ErrorResultView.swift            # Single result display
      Components/
        CommandPalette.swift
        StatusBarView.swift
        LogLevelBadge.swift
        HighlightedText.swift            # Search term highlighting
    Utilities/
      Formatters.swift                   # Date, file size formatting
      Color+Hex.swift                    # Color(hex:) extension
      String+Regex.swift                 # Regex helpers
```

---

## Implementation Phases

### Phase 1: Foundation
- Package.swift and project structure
- Theme system (AppTheme protocol, ThemeManager, Dark/Light/Neon)
- Utility code (Color+Hex, Formatters, WindowAccessor)
- Core models (LogEntry, LogLevel, LogSource, LogFilter, LogDocument)
- AppState with document management
- TraceViewApp with EnvironmentObject injection
- Basic ContentView + WelcomeView shell

### Phase 2: Parsing & Display
- LogParser protocol + PlainTextParser + LevelDetector
- ParserRegistry with auto-detection
- LogDocumentViewModel (load, parse, filter)
- LogTableView + LogRowView with level highlighting
- FilterBarView with search and level chips
- SidebarView with open files
- File > Open via NSOpenPanel

### Phase 3: Real-Time
- FileWatcher (DispatchSource)
- Incremental reading from lastReadOffset
- Auto-follow scroll behavior (bottom anchor detection)
- FollowIndicator + Jump to Bottom button
- Partial line buffering

### Phase 4: Advanced Parsers
- UnifiedLogParser (JSON from `log show/stream`)
- JSONLogParser (structured JSON lines)
- CSVLogParser
- SCCMLogParser (CMTrace format)
- UnifiedLogStream (live `log stream` via Process)

### Phase 5: Error Code System
- Error databases: errno, OSStatus, IOReturn, Mach, HTTP
- ErrorCodeLookup service with multi-format input
- ErrorLookupViewModel
- ErrorLookupPanel UI (inspector)
- Inline error code detection + tappable links in log rows

### Phase 6: Polish
- All keyboard shortcuts + CommandPalette
- SettingsView (theme, font size, custom highlight rules)
- ExportService (filtered log to file)
- Drag-and-drop file opening
- StatusBarView (line count, encoding, follow status)
- Performance testing and optimization

---

## Reuse from MacPerf

| What | How |
|------|-----|
| ThemeManager + ThemeOption enum | Copy, change UserDefaults key prefix to `traceview.` |
| Color(hex:) extension | Copy directly |
| WindowAccessor | Copy, adjust min window size |
| Formatters (formatBytes, formatCount) | Copy, add date formatters |
| AppState pattern | Same ObservableObject + child forwarding, different state |
| SettingsManager pattern | Same UserDefaults + didSet, different settings |
| NavigationSplitView layout | Same structure, different content |
| .commands {} shortcuts | Same pattern, different commands |
| CommandPalette | Adapt with log-specific actions |

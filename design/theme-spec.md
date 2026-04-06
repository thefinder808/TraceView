# TraceView Theme Specification

A precise color and typography system for a professional macOS log viewer.
Every value is intentional — derived from Apple's HIG color science, Xcode's editor palette,
and the information density requirements of log analysis tooling.

---

## Design Philosophy

**Utilitarian precision.** TraceView is a tool for engineers scanning thousands of lines under pressure.
Every color choice serves signal clarity — errors must be unmissable, timestamps must be scannable,
and the background must disappear. No decorative gradients, no unnecessary depth, no visual noise.

The aesthetic reference points are Xcode's debug console, Tower's commit log, and Proxyman's
request inspector — tools that look quiet until something goes wrong, then the problem screams.

---

## Typography

**Monospaced (log content):** SF Mono — the system monospaced font on macOS. Consistent glyph width
is non-negotiable for log alignment. Use `.monospaced()` in SwiftUI, which resolves to SF Mono.

**UI text (labels, sidebar, filter bar):** SF Pro Text (system font) — `.body`, `.caption`, `.headline`.
No custom fonts. This is a tool, not a brand. The system font keeps it native.

**Sizing:**
- Log rows: 12pt SF Mono (matches Xcode console default)
- Line numbers: 11pt SF Mono
- Sidebar labels: 13pt SF Pro (system .body)
- Filter bar labels: 12pt SF Pro
- Status bar: 11pt SF Pro
- Level badges: 10pt SF Pro Medium, uppercased

---

## Dark Theme (Primary)

The default. Optimized for long sessions and low-light environments.
Base palette derived from macOS system dark chrome with subtle warm-neutral shifts
to reduce the "pure black void" feel while maintaining contrast ratios.

### Surfaces
| Token | Hex | RGB | Usage |
|-------|-----|-----|-------|
| `windowBackground` | `#1A1A1E` | 26, 26, 30 | Main window fill |
| `sidebarBackground` | `#232328` | 35, 35, 40 | Sidebar panel |
| `tableBackground` | `#1E1E22` | 30, 30, 34 | Log table area |
| `filterBarBackground` | `#232328` | 35, 35, 40 | Filter bar strip |
| `statusBarBackground` | `#19191D` | 25, 25, 29 | Bottom status bar |
| `cardBackground` | `#28282D` | 40, 40, 45 | Error lookup panel cards |
| `inputBackground` | `#2C2C31` | 44, 44, 49 | Text fields, search box |

### Borders & Dividers
| Token | Hex | Usage |
|-------|-----|-------|
| `border` | `#3A3A3F` | Panel dividers, card borders |
| `borderSubtle` | `#2E2E33` | Inner dividers, row separators |
| `focusRing` | `#4A9EFF` | Focused input outline (40% opacity) |

### Text
| Token | Hex | Usage |
|-------|-----|-------|
| `primaryText` | `#E5E5EA` | Log messages, main content |
| `secondaryText` | `#8E8E93` | Component column, sidebar labels |
| `tertiaryText` | `#636366` | Line numbers, disabled states |
| `timestampText` | `#7EB6FF` | Timestamp column — cool blue, scannable |
| `componentText` | `#A9A9AE` | Component/process column |

### Interactive
| Token | Hex | Usage |
|-------|-----|-------|
| `sidebarHover` | `#2C2C31` | Sidebar row hover |
| `sidebarActive` | `#343439` | Selected sidebar row |
| `tableRowHover` | `#FFFFFF` at 4% | Log row hover |
| `tableRowSelected` | `#4A9EFF` at 15% | Selected log row |
| `accentColor` | `#4A9EFF` | Primary accent — buttons, active states |

### Log Level Colors
These are the most critical colors in the app. They must be:
1. Instantly distinguishable from each other and from default rows
2. Readable — text on highlighted rows must maintain 4.5:1 contrast
3. Not fatiguing — you'll see hundreds of these in a session

| Level | Row Background | Text Color | Badge Background | Badge Text |
|-------|---------------|------------|-----------------|------------|
| Critical | `#FF453A` at 18% (`#3D1F1D`) | `#FF6961` | `#FF453A` | `#FFFFFF` |
| Error | `#FF453A` at 12% (`#351E1C`) | `#FF6961` | `#FF453A` at 85% | `#FFFFFF` |
| Warning | `#FFD60A` at 10% (`#33301A`) | `#FFD60A` | `#FFD60A` at 80% | `#1A1A1E` |
| Notice | transparent | `#E5E5EA` | `#4A9EFF` at 20% | `#7EB6FF` |
| Info | transparent | `#E5E5EA` | `#636366` at 30% | `#A9A9AE` |
| Debug | transparent | `#636366` | `#636366` at 15% | `#636366` |

### Semantic Colors
| Token | Hex | Usage |
|-------|-----|-------|
| `followingIndicator` | `#32D74B` | Green dot/pulse when tailing is active |
| `pausedIndicator` | `#636366` | Gray when tailing is paused |
| `searchHighlight` | `#FFD60A` at 30% | Search match background |
| `searchHighlightActive` | `#FFD60A` at 55% | Current/focused search match |
| `errorCodeLink` | `#64D2FF` | Tappable error codes in log text |
| `liveIndicator` | `#FF9F0A` | Live streaming badge dot |

---

## Light Theme

For well-lit environments. Uses Apple's HIG light system colors as the foundation.
The key challenge: error/warning highlights must be visible on a near-white background
without looking garish.

### Surfaces
| Token | Hex | Usage |
|-------|-----|-------|
| `windowBackground` | `#F5F5F7` | Main window fill |
| `sidebarBackground` | `#EEEFF1` | Sidebar panel |
| `tableBackground` | `#FFFFFF` | Log table area |
| `filterBarBackground` | `#EEEFF1` | Filter bar strip |
| `statusBarBackground` | `#E8E8ED` | Bottom status bar |
| `cardBackground` | `#FFFFFF` | Error lookup panel cards |
| `inputBackground` | `#FFFFFF` | Text fields (with border) |

### Borders & Dividers
| Token | Hex | Usage |
|-------|-----|-------|
| `border` | `#D1D1D6` | Panel dividers |
| `borderSubtle` | `#E5E5EA` | Row separators |
| `focusRing` | `#007AFF` at 40% | Focused input |

### Text
| Token | Hex | Usage |
|-------|-----|-------|
| `primaryText` | `#1D1D1F` | Log messages |
| `secondaryText` | `#86868B` | Component, sidebar |
| `tertiaryText` | `#AEAEB2` | Line numbers |
| `timestampText` | `#0060CC` | Timestamp — darker blue for readability |
| `componentText` | `#6E6E73` | Component column |

### Interactive
| Token | Hex | Usage |
|-------|-----|-------|
| `sidebarHover` | `#E5E5EA` | Sidebar hover |
| `sidebarActive` | `#DCDCE0` | Selected sidebar row |
| `tableRowHover` | `#000000` at 3% | Log row hover |
| `tableRowSelected` | `#007AFF` at 12% | Selected log row |
| `accentColor` | `#007AFF` | Primary accent |

### Log Level Colors (Light)
| Level | Row Background | Text Color | Badge Background | Badge Text |
|-------|---------------|------------|-----------------|------------|
| Critical | `#FF3B30` at 12% (`#FFE4E2`) | `#C5221F` | `#FF3B30` | `#FFFFFF` |
| Error | `#FF3B30` at 8% (`#FFEDEC`) | `#D32F2F` | `#FF3B30` at 85% | `#FFFFFF` |
| Warning | `#FF9500` at 10% (`#FFF3E0`) | `#996300` | `#FF9500` at 85% | `#FFFFFF` |
| Notice | transparent | `#1D1D1F` | `#007AFF` at 12% | `#007AFF` |
| Info | transparent | `#1D1D1F` | `#86868B` at 15% | `#6E6E73` |
| Debug | transparent | `#AEAEB2` | `#AEAEB2` at 12% | `#AEAEB2` |

### Semantic Colors (Light)
| Token | Hex | Usage |
|-------|-----|-------|
| `followingIndicator` | `#34C759` | Following dot |
| `pausedIndicator` | `#AEAEB2` | Paused |
| `searchHighlight` | `#FF9500` at 25% | Search match |
| `searchHighlightActive` | `#FF9500` at 45% | Current match |
| `errorCodeLink` | `#007AFF` | Tappable error codes |
| `liveIndicator` | `#FF9500` | Live badge |

---

## Neon Theme

For users who want a high-saturation, high-contrast experience. Inspired by
terminal emulators like Warp and Hyper. This is the "fun" option — still
functional, but with personality.

### Surfaces
| Token | Hex | Usage |
|-------|-----|-------|
| `windowBackground` | `#0D0D12` | Near-black base |
| `sidebarBackground` | `#12121A` | Sidebar |
| `tableBackground` | `#0F0F16` | Log table |
| `filterBarBackground` | `#12121A` | Filter bar |
| `statusBarBackground` | `#0A0A10` | Status bar |
| `cardBackground` | `#18182A` | Cards |
| `inputBackground` | `#1A1A2E` | Inputs |

### Borders
| Token | Hex | Usage |
|-------|-----|-------|
| `border` | `#2A2A40` | Panel dividers |
| `borderSubtle` | `#1E1E30` | Row separators |
| `focusRing` | `#00D4FF` at 50% | Focus ring — cyan glow |

### Text
| Token | Hex | Usage |
|-------|-----|-------|
| `primaryText` | `#E0E0F0` | Cool-white log text |
| `secondaryText` | `#7878A0` | Supporting text |
| `tertiaryText` | `#4A4A6A` | Line numbers |
| `timestampText` | `#00D4FF` | Cyan timestamps |
| `componentText` | `#9898C0` | Component column |

### Log Level Colors (Neon)
| Level | Row Background | Text Color | Badge Background | Badge Text |
|-------|---------------|------------|-----------------|------------|
| Critical | `#FF0040` at 20% | `#FF4070` | `#FF0040` | `#FFFFFF` |
| Error | `#FF0040` at 14% | `#FF4070` | `#FF0040` at 85% | `#FFFFFF` |
| Warning | `#FFE000` at 12% | `#FFE000` | `#FFE000` at 80% | `#0D0D12` |
| Notice | transparent | `#E0E0F0` | `#00D4FF` at 20% | `#00D4FF` |
| Info | transparent | `#E0E0F0` | `#4A4A6A` at 30% | `#7878A0` |
| Debug | transparent | `#4A4A6A` | `#4A4A6A` at 15% | `#4A4A6A` |

### Semantic (Neon)
| Token | Hex | Usage |
|-------|-----|-------|
| `accentColor` | `#00D4FF` | Cyan accent |
| `followingIndicator` | `#00FF88` | Bright green |
| `pausedIndicator` | `#4A4A6A` | Dim |
| `searchHighlight` | `#FFE000` at 30% | Yellow search |
| `errorCodeLink` | `#00D4FF` | Cyan links |
| `liveIndicator` | `#FF6600` | Orange live |
| `glowEnabled` | `true` | Subtle glow on accent elements |

---

## Level Badge Design

Badges are the small pills in the Level column. They must be compact, readable,
and instantly recognizable by color alone (accessibility note: also by text).

**Dimensions:** Height 18px, horizontal padding 6px, border-radius 4px
**Typography:** 10pt SF Pro Medium, uppercased, letter-spacing 0.3pt
**Layout:** Centered in the Level column (fixed 64px width)

```
 +---------+
 | ERROR   |  <- Red badge, white text
 +---------+

 +---------+
 | WARN    |  <- Yellow/orange badge, dark text (dark theme) or white text (light)
 +---------+

 +---------+
 | INFO    |  <- Subtle gray badge, muted text
 +---------+
```

---

## Row Design

Each log row is exactly 24px tall (fixed, no variance). This is critical for
virtual scroll performance.

```
| 4px | Line# 48px | 8px | Timestamp 140px | 8px | Level 64px | 8px | Component 120px | 8px | Message flex | 4px |
```

- Line number: right-aligned, tertiaryText, 11pt SF Mono
- Timestamp: left-aligned, timestampText, 12pt SF Mono
- Level: centered badge (see above)
- Component: left-aligned, truncated, componentText, 12pt SF Mono
- Message: left-aligned, primaryText, 12pt SF Mono, fills remaining space

Row separator: 1px `borderSubtle` between rows (or alternating row tint at 2% for zebra striping).

Error/warning rows: full-width background tint (the entire row, edge to edge).

Selected row: `tableRowSelected` background, overrides level highlight.
Hover row: `tableRowHover` background, layered under level highlight.

---

## Filter Bar Design

Height: 36px. Sits directly above the log table, flush with the table edges.

```
| 12px | [magnifying glass] [Search field 240px] [.*] [Aa] | 16px | [DBG] [INF] [NOT] [WRN] [ERR] [CRT] | flex | 42 of 45,231 | 12px |
```

- Search field: `inputBackground` fill, `border` stroke, rounded 6px, 12pt SF Pro
- Regex toggle `.*`: 24x24 button, `accentColor` when active
- Case toggle `Aa`: 24x24 button, `accentColor` when active
- Level chips: each 28px tall, 6px border-radius, colored by level badge color, toggleable (dimmed when off)
- Match count: right-aligned, `secondaryText`, 11pt SF Pro

---

## Status Bar Design

Height: 28px. Bottom edge of the window.

```
| 12px | [icon] 45,231 lines | divider | UTF-8 | divider | 2.3 MB | flex | [* Following] or [Paused] | 12px |
```

- Background: `statusBarBackground`
- Text: `secondaryText`, 11pt SF Pro
- Following indicator: small 6px circle (`followingIndicator` color) + "Following" text
  - When active: circle has a subtle pulse animation (opacity 0.6 -> 1.0, 2s ease)
- Paused: gray circle + "Paused" text
- Dividers: 1px vertical `borderSubtle`, 16px tall, centered

---

## Sidebar Design

Width: 220px default (resizable 180-300px).

### Section Headers
- "OPEN FILES" / "SYSTEM LOGS" — 10pt SF Pro Medium, uppercased, `tertiaryText`, letter-spacing 0.5pt
- 24px height, 12px left padding

### Document Rows
- Height: 36px
- Left padding: 12px
- Icon: 14px SF Symbol (`doc.text` for files, `waveform` for live streams)
- Filename: 13pt SF Pro, `primaryText`, truncated
- Line count badge: right side, 10pt SF Pro, `secondaryText`, `cardBackground` pill
- Live indicator: small 6px dot (`liveIndicator` color) next to filename

### Bottom Bar
- Settings gear icon, 13pt, `secondaryText`
- 36px height, centered, top border `borderSubtle`

---

## Error Lookup Panel Design

Width: 280px default (resizable 260-380px). Slides in from right edge.

### Header
- "Error Lookup" title, 13pt SF Pro Semibold
- Close button (X), right side

### Input Area
- Text field: full width, `inputBackground`, rounded 6px
- Placeholder: "Enter error code..."
- Domain selector: segmented control below — Auto | errno | OSStatus | IOReturn | Mach | HTTP
  - 10pt SF Pro, compact segments

### Results
- Each result is a card (`cardBackground`, `border`, rounded 8px):
  - Domain badge (small colored pill, top-left)
  - Symbolic name: 13pt SF Mono Bold (`primaryText`)
  - Values: "Decimal: -43 | Hex: 0xFFFFFFD5" — 11pt SF Mono, `secondaryText`
  - Description: 12pt SF Pro, `primaryText`
  - Copy button: subtle, right edge

### Recent Lookups
- Section header: "RECENT" — same style as sidebar headers
- List of recent codes, tappable, 12pt SF Mono, `secondaryText`

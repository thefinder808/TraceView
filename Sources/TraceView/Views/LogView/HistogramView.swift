import SwiftUI

// Event-density histogram strip. Buckets timestamped entries into ~60 bins
// across the log's time span and stacks error / warning / info bars per bin.
// Hidden when fewer than 10% of entries have parsed timestamps.
struct HistogramView: View {
    @ObservedObject var viewModel: LogDocumentViewModel
    @EnvironmentObject var themeManager: ThemeManager

    private let bucketCount = 60
    private let stripHeight: CGFloat = 28

    var body: some View {
        let theme = themeManager.current

        Group {
            if let bins = computeBuckets() {
                VStack(spacing: 2) {
                    HStack(alignment: .bottom, spacing: 1) {
                        ForEach(bins.bars.indices, id: \.self) { i in
                            barColumn(bar: bins.bars[i], maxTotal: bins.maxTotal, theme: theme)
                        }
                    }
                    .frame(height: stripHeight)
                    .background(theme.borderSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(alignment: .trailing) {
                        // "Now" marker at the trailing edge
                        Rectangle()
                            .fill(theme.accentColor)
                            .frame(width: 1.5)
                    }

                    HStack {
                        Text(bins.startLabel)
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .foregroundStyle(theme.tertiaryText)
                        Spacer()
                        Text(bins.endLabel)
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(theme.filterBarBackground)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.borderSubtle).frame(height: 1)
                }
            } else {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func barColumn(bar: Bar, maxTotal: Int, theme: any AppTheme) -> some View {
        let heightFactor = maxTotal == 0 ? 0.0 : Double(bar.total) / Double(maxTotal)
        GeometryReader { geo in
            let fullH = geo.size.height
            let barH = fullH * heightFactor
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack(alignment: .bottom) {
                    Rectangle()
                        .fill(theme.tertiaryText.opacity(0.35))
                        .frame(height: barH)
                    VStack(spacing: 0) {
                        if bar.err > 0 {
                            Rectangle()
                                .fill(theme.errorText)
                                .frame(height: barH * (Double(bar.err) / Double(max(bar.total, 1))))
                        }
                        if bar.warn > 0 {
                            Rectangle()
                                .fill(theme.warningText)
                                .frame(height: barH * (Double(bar.warn) / Double(max(bar.total, 1))))
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: barH, alignment: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bucketing

    private struct Bar { let err: Int; let warn: Int; let info: Int; var total: Int { err + warn + info } }
    private struct Buckets { let bars: [Bar]; let maxTotal: Int; let startLabel: String; let endLabel: String }

    private func computeBuckets() -> Buckets? {
        let entries = viewModel.document.entries
        guard entries.count >= 10 else { return nil }

        let timestamped = entries.compactMap { $0.timestamp }
        guard Double(timestamped.count) / Double(entries.count) >= 0.1,
              let first = timestamped.first,
              let last = timestamped.last,
              last > first else { return nil }

        let total = last.timeIntervalSince(first)
        guard total > 0 else { return nil }

        let bucketSize = total / Double(bucketCount)
        var bars = Array(repeating: Bar(err: 0, warn: 0, info: 0), count: bucketCount)

        for entry in entries {
            guard let ts = entry.timestamp else { continue }
            let offset = ts.timeIntervalSince(first)
            let idx = min(bucketCount - 1, max(0, Int(offset / bucketSize)))
            let existing = bars[idx]
            switch entry.level {
            case .error, .critical:
                bars[idx] = Bar(err: existing.err + 1, warn: existing.warn, info: existing.info)
            case .warning:
                bars[idx] = Bar(err: existing.err, warn: existing.warn + 1, info: existing.info)
            default:
                bars[idx] = Bar(err: existing.err, warn: existing.warn, info: existing.info + 1)
            }
        }

        let maxTotal = bars.map(\.total).max() ?? 1

        let fmt = DateFormatter()
        fmt.dateFormat = total > 86400 ? "MMM d HH:mm" : "HH:mm:ss"

        return Buckets(
            bars: bars,
            maxTotal: maxTotal,
            startLabel: fmt.string(from: first),
            endLabel: fmt.string(from: last)
        )
    }
}

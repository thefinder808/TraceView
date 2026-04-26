import SwiftUI

// Event-density histogram strip. Buckets are computed on the document
// (see `recomputeHistogram`) so this view just reads the cached result —
// no O(N) pass on every SwiftUI body evaluation, and no duplicate work
// when the same doc is shown in both split panes. Hidden when fewer than
// 10% of entries have parsed timestamps.
struct HistogramView: View {
    @ObservedObject var document: LogDocument
    @EnvironmentObject var themeManager: ThemeManager

    /// Fired when the user clicks a bucket. Caller resolves the bucket's
    /// time range to a concrete entry and navigates. Disabled state is
    /// naturally handled by the histogram being hidden.
    var onBucketClick: (Int) -> Void = { _ in }

    @State private var hoveredBucket: Int?

    private let stripHeight: CGFloat = 28

    var body: some View {
        let theme = themeManager.current

        if let bins = document.histogram {
            VStack(spacing: 2) {
                barStrip(bins: bins, theme: theme)
                rangeLabels(bins: bins, theme: theme)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(theme.filterBarBackground)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.borderSubtle).frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private func barStrip(bins: LogHistogram, theme: any AppTheme) -> some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(bins.bars.indices, id: \.self) { i in
                interactiveBar(index: i, bins: bins, theme: theme)
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
    }

    @ViewBuilder
    private func interactiveBar(index i: Int, bins: LogHistogram, theme: any AppTheme) -> some View {
        ZStack(alignment: .bottom) {
            shadowOverlay(forBucket: i, bins: bins, theme: theme)
            barColumn(
                bar: bins.bars[i],
                maxTotal: bins.maxTotal,
                theme: theme,
                isHovered: hoveredBucket == i
            )
        }
        .contentShape(Rectangle())
        .onTapGesture { onBucketClick(i) }
        .onHover { hovering in
            if hovering {
                hoveredBucket = i
            } else if hoveredBucket == i {
                hoveredBucket = nil
            }
        }
        .hoverTooltip(
            tooltipText(for: i, histogram: bins),
            edge: .top,
            delay: .milliseconds(150)
        )
    }

    @ViewBuilder
    private func rangeLabels(bins: LogHistogram, theme: any AppTheme) -> some View {
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

    /// Faint "all-time peak" ghost rendered behind the solid bar. Returns
    /// EmptyView when the bucket has no shadow recorded — most buckets
    /// most of the time. Color is theme.errorText at 0.25 alpha (single
    /// uniform color; the ghost simplifies away the err/warn/info
    /// breakdown, just signaling "there was a spike here at some point").
    @ViewBuilder
    private func shadowOverlay(forBucket index: Int, bins: LogHistogram, theme: any AppTheme) -> some View {
        if let shadow = bins.shadows.first(where: { $0.bucketIndex == index }) {
            GeometryReader { geo in
                let height = geo.size.height * CGFloat(shadow.peakCount) / CGFloat(max(bins.maxTotal, 1))
                Rectangle()
                    .fill(theme.errorText.opacity(0.25))
                    .frame(height: height)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    @ViewBuilder
    private func barColumn(bar: LogHistogram.Bar, maxTotal: Int, theme: any AppTheme, isHovered: Bool) -> some View {
        let heightFactor = maxTotal == 0 ? 0.0 : Double(bar.total) / Double(maxTotal)
        GeometryReader { geo in
            let fullH = geo.size.height
            let barH = fullH * heightFactor
            ZStack {
                // Hover column highlight — covers the full bucket cell,
                // not just the bar height, so tiny buckets are still an
                // obvious click target.
                if isHovered {
                    Rectangle()
                        .fill(theme.accentColor.opacity(0.18))
                }

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .fill(theme.tertiaryText.opacity(isHovered ? 0.55 : 0.35))
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
        }
        .frame(maxWidth: .infinity)
    }

    private func tooltipText(for bucketIndex: Int, histogram: LogHistogram) -> String {
        let range = histogram.timeRange(forBucket: bucketIndex)
        let timeLabel = Self.tooltipTimeFormatter.string(from: range.start)
        let count = histogram.bars[bucketIndex].total
        let countLabel = count == 1 ? "1 event" : "\(count) events"
        return "\(timeLabel) — \(countLabel)"
    }

    private static let tooltipTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

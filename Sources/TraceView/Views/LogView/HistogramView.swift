import SwiftUI

// Event-density histogram strip. Buckets are computed in
// LogDocumentViewModel (see `recomputeHistogram`) so this view just reads
// the cached result — no O(N) pass on every SwiftUI body evaluation.
// Hidden when fewer than 10% of entries have parsed timestamps.
struct HistogramView: View {
    @ObservedObject var viewModel: LogDocumentViewModel
    @EnvironmentObject var themeManager: ThemeManager

    private let stripHeight: CGFloat = 28

    var body: some View {
        let theme = themeManager.current

        if let bins = viewModel.histogram {
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
        }
    }

    @ViewBuilder
    private func barColumn(bar: LogHistogram.Bar, maxTotal: Int, theme: any AppTheme) -> some View {
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
}

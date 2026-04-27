import SwiftUI

struct ErrorLookupPanel: View {
    @StateObject private var viewModel = ErrorLookupViewModel()
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let theme = themeManager.current

        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Error Lookup")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                Spacer()

                Button {
                    appState.showErrorLookup = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.tertiaryText)
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(theme.sidebarBackground)

            Divider().background(theme.border)

            // Body
            ScrollView {
                VStack(spacing: 12) {
                    // Search field
                    TextField("Enter error code...", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    // Domain tabs
                    domainTabs(theme: theme)

                    // Results
                    ForEach(viewModel.results) { result in
                        ErrorResultCard(result: result, theme: theme)
                    }

                    // Empty state — spell out the database scope so a
                    // legitimate "no match" reads as an answer, not a bug.
                    if viewModel.results.isEmpty && !viewModel.searchText.isEmpty {
                        VStack(spacing: 4) {
                            Text("Not in the built-in database")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.secondaryText)
                            Text(ErrorDomain.allCases.map { $0.displayName }.joined(separator: " · "))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .font(.system(size: 10))
                                .foregroundStyle(theme.tertiaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }

                    // Recent lookups
                    if !viewModel.recentLookups.isEmpty && viewModel.searchText.isEmpty {
                        recentSection(theme: theme)
                    }
                }
                .padding(12)
            }
            .background(theme.sidebarBackground)
        }
        .onAppear { consumePendingCode() }
        .onChange(of: appState.pendingErrorLookupCode) { _, _ in consumePendingCode() }
    }

    private func consumePendingCode() {
        guard let code = appState.pendingErrorLookupCode, !code.isEmpty else { return }
        viewModel.lookupCode(code)
        appState.pendingErrorLookupCode = nil
    }

    // MARK: - Domain Tabs

    private func domainTabs(theme: any AppTheme) -> some View {
        // Horizontal scroll because 13 domains overflow the sidebar width.
        // ScrollView's content does not get a clipShape from its parent, so we
        // apply the rounded background to the ScrollView itself.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                domainTab(label: "Auto", domain: nil, theme: theme)
                ForEach(ErrorDomain.allCases) { domain in
                    domainTab(label: domain.displayName, domain: domain, theme: theme)
                }
            }
            .padding(2)
        }
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func domainTab(label: String, domain: ErrorDomain?, theme: any AppTheme) -> some View {
        let isActive = viewModel.selectedDomain == domain

        return Button {
            viewModel.selectedDomain = domain
        } label: {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.2)
                .foregroundStyle(isActive ? .white : theme.tertiaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(isActive ? theme.accentColor : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recents

    private func recentSection(theme: any AppTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECENT")
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(theme.tertiaryText)

            ForEach(viewModel.recentLookups.prefix(10), id: \.input) { recent in
                Button {
                    viewModel.lookupCode(recent.input)
                } label: {
                    HStack(spacing: 8) {
                        Text(recent.input)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)

                        Text(recent.label)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.tertiaryText)

                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Result Card

struct ErrorResultCard: View {
    let result: ErrorCodeInfo
    let theme: any AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Domain badge
            Text(result.domain.displayName)
                .font(.system(size: 9, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.3)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(theme.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 3))

            // Symbolic name
            Text(result.symbolicName)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.primaryText)

            // Values
            Text(result.formattedCode)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.secondaryText)

            // Description
            Text(result.description)
                .font(.system(size: 12))
                .foregroundStyle(theme.primaryText)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(theme.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

import SwiftUI
import Combine

final class ErrorLookupViewModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var selectedDomain: ErrorDomain? = nil // nil = Auto
    @Published var results: [ErrorCodeInfo] = []
    @Published var recentLookups: [(input: String, label: String)] = []

    private var cancellables = Set<AnyCancellable>()
    private let lookup = ErrorCodeLookup.shared
    private static let recentsKey = "traceview.recentErrorLookups"

    init() {
        loadRecents()
        setupSearch()
    }

    private func setupSearch() {
        $searchText
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] text in
                self?.performLookup(text)
            }
            .store(in: &cancellables)

        $selectedDomain
            .sink { [weak self] _ in
                guard let self, !self.searchText.isEmpty else { return }
                self.performLookup(self.searchText)
            }
            .store(in: &cancellables)
    }

    func performLookup(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }

        if let domain = selectedDomain {
            results = lookup.lookup(input: trimmed, domain: domain)
        } else {
            results = lookup.lookup(input: trimmed)
        }

        // Add to recents if we got results
        if let first = results.first {
            addRecent(input: trimmed, label: first.symbolicName)
        }
    }

    func lookupCode(_ code: String) {
        searchText = code
    }

    // MARK: - Recents

    private func addRecent(input: String, label: String) {
        // Remove duplicate
        recentLookups.removeAll { $0.input == input }
        // Prepend
        recentLookups.insert((input: input, label: label), at: 0)
        // Cap at 20
        if recentLookups.count > 20 {
            recentLookups = Array(recentLookups.prefix(20))
        }
        saveRecents()
    }

    private func loadRecents() {
        guard let saved = UserDefaults.standard.array(forKey: Self.recentsKey) as? [[String]] else { return }
        recentLookups = saved.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return (input: pair[0], label: pair[1])
        }
    }

    private func saveRecents() {
        let data = recentLookups.map { [$0.input, $0.label] }
        UserDefaults.standard.set(data, forKey: Self.recentsKey)
    }
}

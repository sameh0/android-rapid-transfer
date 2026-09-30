import Foundation

struct BrowserEntryFilterCache {
    private var entries: [BrowserEntry] = []
    private var cachedQuery: String?
    private var cachedEntries: [BrowserEntry] = []

    mutating func updateEntries(_ entries: [BrowserEntry]) {
        self.entries = entries
        cachedQuery = nil
        cachedEntries = []
    }

    mutating func entries(matching query: String) -> [BrowserEntry] {
        guard !query.isEmpty else { return entries }
        if cachedQuery != query {
            cachedQuery = query
            cachedEntries = entries.filter {
                $0.name.localizedStandardContains(query)
            }
        }
        return cachedEntries
    }
}

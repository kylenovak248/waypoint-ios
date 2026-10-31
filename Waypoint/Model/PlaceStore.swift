import Foundation

/// Favorites, routes and history, saved as JSON in Application Support.
@MainActor
final class PlaceStore: ObservableObject {
    @Published var favorites: [Place] = [] { didSet { save() } }
    @Published var routes: [SavedRoute] = [] { didSet { save() } }
    @Published var history: [HistoryItem] = [] { didSet { save() } }

    private struct Snapshot: Codable {
        var favorites: [Place]
        var routes: [SavedRoute]
        var history: [HistoryItem]
    }

    private let fileURL: URL
    private var loading = false

    init(fileURL: URL = AppPaths.support.appendingPathComponent("places.json")) {
        self.fileURL = fileURL
        load()
    }

    private func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            favorites = Self.starterPlaces
            return
        }
        favorites = snapshot.favorites
        routes = snapshot.routes
        history = snapshot.history
    }

    private func save() {
        guard !loading else { return }
        let snapshot = Snapshot(favorites: favorites, routes: routes, history: history)
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[Waypoint] Could not save places: \(error)")
        }
    }

    func isFavorite(_ place: Place) -> Bool { favorites.contains { $0.sameSpot(as: place) } }

    func toggleFavorite(_ place: Place) {
        if let index = favorites.firstIndex(where: { $0.sameSpot(as: place) }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(place, at: 0)
        }
    }

    func addHistory(_ place: Place, kind: HistoryItem.Kind) {
        // Repeating the latest entry just refreshes its time.
        if let first = history.first, first.place.sameSpot(as: place), first.kind == kind {
            history[0].date = Date()
            return
        }
        history.insert(HistoryItem(place: place, kind: kind, date: Date()), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
    }

    static let starterPlaces: [Place] = [
        Place(name: "New York", detail: "United States", latitude: 40.7128, longitude: -74.0060),
        Place(name: "London", detail: "United Kingdom", latitude: 51.5072, longitude: -0.1276),
        Place(name: "Tokyo", detail: "Japan", latitude: 35.6762, longitude: 139.6503),
        Place(name: "Sydney", detail: "Australia", latitude: -33.8688, longitude: 151.2093),
    ]
}

enum AppPaths {
    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Waypoint", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var pairingFile: URL { support.appendingPathComponent("pairing.plist") }
    static var ddiDirectory: URL { support.appendingPathComponent("DDI", isDirectory: true) }
    static var logFile: URL { support.appendingPathComponent("idevice.log") }
}

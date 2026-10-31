import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var store: PlaceStore
    @EnvironmentObject private var device: DeviceService
    @EnvironmentObject private var router: Router

    var body: some View {
        NavigationStack {
            Group {
                if store.favorites.isEmpty {
                    ContentUnavailableView("No favorites yet",
                                           systemImage: "star",
                                           description: Text("Tap the star on a place in Explore to save it here."))
                } else {
                    List {
                        ForEach(store.favorites) { place in
                            PlaceRow(place: place) {
                                Task { await setLocation(place) }
                            }
                            .swipeActions {
                                Button(role: .destructive) { store.toggleFavorite(place) } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                                Button { router.show(place) } label: { Label("Map", systemImage: "map") }
                                    .tint(.blue)
                            }
                        }
                        .onMove { store.favorites.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .toolbar { EditButton() }
                }
            }
            .navigationTitle("Favorites")
        }
    }

    private func setLocation(_ place: Place) async {
        do {
            try await device.setLocation(place)
            router.show(place)
            router.toast("Location set to \(place.name).")
        } catch {
            router.toast(error.localizedDescription, error: true)
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var store: PlaceStore
    @EnvironmentObject private var device: DeviceService
    @EnvironmentObject private var router: Router
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if store.history.isEmpty {
                    ContentUnavailableView("No history yet",
                                           systemImage: "clock",
                                           description: Text("Locations and finished routes appear here."))
                } else {
                    List {
                        ForEach(store.history) { item in
                            PlaceRow(place: item.place,
                                     caption: "\(item.kind.rawValue) · \(item.date.formatted(date: .abbreviated, time: .shortened))") {
                                Task { await setLocation(item.place) }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    store.history.removeAll { $0.id == item.id }
                                } label: { Label("Delete", systemImage: "trash") }
                                Button { store.toggleFavorite(item.place) } label: {
                                    Label(store.isFavorite(item.place) ? "Unfavorite" : "Favorite", systemImage: "star")
                                }
                                .tint(.yellow)
                            }
                        }
                    }
                    .toolbar {
                        Button("Clear", role: .destructive) { confirmClear = true }
                    }
                    .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("Clear History", role: .destructive) { store.history.removeAll() }
                    }
                }
            }
            .navigationTitle("History")
        }
    }

    private func setLocation(_ place: Place) async {
        do {
            try await device.setLocation(place)
            router.show(place)
            router.toast("Location set to \(place.name).")
        } catch {
            router.toast(error.localizedDescription, error: true)
        }
    }
}

struct PlaceRow: View {
    let place: Place
    var caption: String? = nil
    let onGo: () -> Void
    @EnvironmentObject private var device: DeviceService

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(.body.weight(.medium)).lineLimit(1)
                Text(caption ?? place.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Go", action: onGo)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(device.isBusy)
        }
    }
}

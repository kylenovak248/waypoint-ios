import MapKit
import SwiftUI

struct RoutesView: View {
    @EnvironmentObject private var store: PlaceStore
    @EnvironmentObject private var device: DeviceService
    @EnvironmentObject private var router: Router
    @State private var editing: SavedRoute?

    var body: some View {
        NavigationStack {
            List {
                if let progress = device.routeProgress {
                    Section {
                        RouteProgressCard(progress: progress)
                            .listRowInsets(EdgeInsets())
                        Button("Restore Real Location", role: .destructive) {
                            Task { await device.clearLocation(); router.toast("Real location restored.") }
                        }
                    }
                }
                Section {
                    Button {
                        editing = SavedRoute(name: "Route \(store.routes.count + 1)", points: [], speedKmh: SpeedPreset.walk.rawValue)
                    } label: {
                        Label("New Route", systemImage: "plus.circle.fill")
                    }
                }
                if !store.routes.isEmpty {
                    Section("Saved routes") {
                        ForEach(store.routes) { route in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(route.name).font(.body.weight(.medium))
                                    Text("\(route.points.count) stops · \(String(format: "%.2f km", route.distanceKm)) · \(Int(route.speedKmh)) km/h · \(Geo.formatDuration(route.durationSeconds))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Play") { Task { await play(route) } }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(device.isBusy)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { editing = route }
                            .swipeActions {
                                Button(role: .destructive) {
                                    store.routes.removeAll { $0.id == route.id }
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Routes")
            .sheet(item: $editing) { route in
                RouteEditorView(route: route) { saved in
                    if let index = store.routes.firstIndex(where: { $0.id == saved.id }) {
                        store.routes[index] = saved
                    } else {
                        store.routes.insert(saved, at: 0)
                    }
                } onPlay: { saved in
                    Task { await play(saved) }
                }
            }
        }
    }

    private func play(_ route: SavedRoute) async {
        do {
            try await device.playRoute(route)
            router.tab = .explore
            if let first = route.points.first { router.cameraTarget = first.coordinate }
            router.toast("Playing \(route.name).")
        } catch {
            router.toast(error.localizedDescription, error: true)
        }
    }
}

struct RouteEditorView: View {
    @State var route: SavedRoute
    var onSave: (SavedRoute) -> Void
    var onPlay: (SavedRoute) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PlaceStore
    @State private var position: MapCameraPosition = .automatic
    @State private var showFavorites = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapReader { proxy in
                    Map(position: $position) {
                        if route.points.count > 1 {
                            MapPolyline(coordinates: route.points.map(\.coordinate))
                                .stroke(Theme.coral, lineWidth: 4)
                        }
                        ForEach(Array(route.points.enumerated()), id: \.element.id) { index, point in
                            Annotation("", coordinate: point.coordinate) {
                                Text("\(index + 1)")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .background(Theme.coral, in: Circle())
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                            }
                        }
                    }
                    .onTapGesture { point in
                        guard let coordinate = proxy.convert(point, from: .local) else { return }
                        route.points.append(Place.at(coordinate, name: "Stop \(route.points.count + 1)"))
                    }
                }
                .frame(minHeight: 260)
                .overlay(alignment: .top) {
                    Text("Tap the map to add stops")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                }

                Form {
                    Section {
                        TextField("Route name", text: $route.name)
                    }
                    Section("Speed") {
                        Picker("Preset", selection: Binding(
                            get: { SpeedPreset(rawValue: route.speedKmh) },
                            set: { if let preset = $0 { route.speedKmh = preset.rawValue } }
                        )) {
                            ForEach(SpeedPreset.allCases) { Text($0.label).tag(Optional($0)) }
                            if SpeedPreset(rawValue: route.speedKmh) == nil {
                                Text("Custom").tag(SpeedPreset?.none)
                            }
                        }
                        .pickerStyle(.segmented)
                        Stepper(value: $route.speedKmh, in: 1...300, step: 1) {
                            Text("\(Int(route.speedKmh)) km/h")
                        }
                        Text("\(String(format: "%.2f km", route.distanceKm)) · about \(Geo.formatDuration(route.durationSeconds))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Stops") {
                        if route.points.isEmpty {
                            Text("No stops yet").foregroundStyle(.secondary)
                        }
                        ForEach(Array(route.points.enumerated()), id: \.element.id) { index, point in
                            VStack(alignment: .leading) {
                                Text("\(index + 1). \(point.name)")
                                Text(point.coordinateText).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { route.points.remove(atOffsets: $0) }
                        .onMove { route.points.move(fromOffsets: $0, toOffset: $1) }
                        Button { showFavorites = true } label: {
                            Label("Add a favorite as a stop", systemImage: "star")
                        }
                        .disabled(store.favorites.isEmpty)
                        if !route.points.isEmpty {
                            Button("Fit route on map") { fit() }
                        }
                    }
                }
            }
            .navigationTitle(route.points.isEmpty ? "New Route" : route.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(route); dismiss() }
                        .disabled(route.points.count < 2 || route.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        onSave(route)
                        dismiss()
                        onPlay(route)
                    } label: {
                        Label("Save and Play", systemImage: "play.fill")
                    }
                    .disabled(route.points.count < 2)
                }
            }
            .confirmationDialog("Add a favorite", isPresented: $showFavorites) {
                ForEach(store.favorites) { place in
                    Button(place.name) { route.points.append(place.withNewID()) }
                }
            }
            .onAppear { if !route.points.isEmpty { fit() } }
        }
    }

    private func fit() {
        let coordinates = route.points.map(\.coordinate)
        guard let first = coordinates.first else { return }
        var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 0, height: 0))
        for coordinate in coordinates { rect = rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 0, height: 0))) }
        let padding = max(rect.size.width, rect.size.height) * 0.25 + 2000
        withAnimation { position = .rect(rect.insetBy(dx: -padding, dy: -padding)) }
    }
}

extension Place {
    func withNewID() -> Place {
        var copy = self
        copy.id = UUID()
        return copy
    }
}

import MapKit
import SwiftUI

enum MapLook: String, CaseIterable, Identifiable {
    case standard = "Streets", hybrid = "Hybrid", satellite = "Satellite"
    var id: String { rawValue }
    var style: MapStyle {
        switch self {
        case .standard: .standard(elevation: .realistic)
        case .hybrid: .hybrid(elevation: .realistic)
        case .satellite: .imagery(elevation: .realistic)
        }
    }
}

struct ExploreView: View {
    @EnvironmentObject private var store: PlaceStore
    @EnvironmentObject private var device: DeviceService
    @EnvironmentObject private var router: Router

    @State private var position: MapCameraPosition = .automatic
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searching = false
    @AppStorage("mapLook") private var look: MapLook = .standard
    @State private var showCoordinates = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $position) {
                    if let selected = router.selected {
                        Marker(selected.name, systemImage: "mappin", coordinate: selected.coordinate)
                            .tint(Theme.coral)
                    }
                    if let simulated = device.simulated {
                        Annotation("Simulated", coordinate: simulated.coordinate) {
                            SimulatedDot()
                        }
                    }
                    if device.routePath.count > 1 {
                        MapPolyline(coordinates: device.routePath)
                            .stroke(Theme.coral, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [8, 6]))
                        if let progress = device.routeProgress,
                           let here = Geo.point(along: device.routePath, km: progress.travelledKm) {
                            Annotation("Route", coordinate: here) { SimulatedDot() }
                        }
                    }
                }
                .mapStyle(look.style)
                .mapControls {
                    MapCompass()
                    MapScaleView()
                    MapPitchToggle()
                }
                .onTapGesture { point in
                    guard let coordinate = proxy.convert(point, from: .local) else { return }
                    searchFocused = false
                    results = []
                    router.selected = Place.at(coordinate)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .top) { searchBar }
            .safeAreaInset(edge: .bottom) { bottomCard }
            .onChange(of: router.cameraTarget?.latitude) { _, _ in moveCamera() }
            .onAppear { moveCamera() }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showCoordinates) {
                CoordinateEntryView { place in
                    router.selected = place
                    router.cameraTarget = place.coordinate
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func moveCamera() {
        guard let target = router.cameraTarget else { return }
        withAnimation {
            position = .camera(MapCamera(centerCoordinate: target, distance: 4000))
        }
        router.cameraTarget = nil
    }

    // MARK: Search

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search places or enter lat, long", text: $query)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit(search)
                    if searching { ProgressView().controlSize(.small) }
                    if !query.isEmpty {
                        Button { query = ""; results = [] } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                Menu {
                    Picker("Map", selection: $look) {
                        ForEach(MapLook.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button { showCoordinates = true } label: { Label("Enter coordinates", systemImage: "number") }
                    if let simulated = device.simulated {
                        Button { router.cameraTarget = simulated.coordinate } label: {
                            Label("Center on simulated location", systemImage: "location.fill")
                        }
                    }
                } label: {
                    Image(systemName: "square.3.layers.3d")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            HStack {
                DeviceStatusPill()
                Spacer()
            }
            if !results.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(results) { place in
                            Button {
                                router.selected = place
                                router.cameraTarget = place.coordinate
                                results = []
                                searchFocused = false
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.name).font(.body.weight(.medium))
                                    Text(place.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 12)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 280)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let coordinate = Geo.parseCoordinates(text) {
            let place = Place.at(coordinate, name: "Coordinates")
            router.selected = place
            router.cameraTarget = coordinate
            results = []
            searchFocused = false
            return
        }
        searching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        MKLocalSearch(request: request).start { response, _ in
            searching = false
            let items = response?.mapItems ?? []
            results = items.prefix(12).map { item in
                Place(name: item.name ?? text,
                      detail: Self.describe(item.placemark),
                      latitude: item.placemark.coordinate.latitude,
                      longitude: item.placemark.coordinate.longitude)
            }
            if results.isEmpty { router.toast("No places found for “\(text)”.", error: true) }
        }
    }

    private static func describe(_ placemark: MKPlacemark) -> String {
        [placemark.thoroughfare, placemark.locality, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    // MARK: Bottom card

    @ViewBuilder
    private var bottomCard: some View {
        VStack(spacing: 10) {
            if let progress = device.routeProgress {
                RouteProgressCard(progress: progress)
            }
            if let place = router.selected {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name).font(.headline).lineLimit(1)
                            Text(place.detail == place.coordinateText ? place.coordinateText : "\(place.detail)\n\(place.coordinateText)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button { store.toggleFavorite(place) } label: {
                            Image(systemName: store.isFavorite(place) ? "star.fill" : "star")
                                .font(.title3)
                                .foregroundStyle(store.isFavorite(place) ? .yellow : .secondary)
                        }
                        Button { router.selected = nil } label: {
                            Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                        }
                    }
                    Button { Task { await go(to: place) } } label: {
                        Label("Set Location", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(device.isBusy)
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else if device.simulated == nil && device.routeProgress == nil {
                Text("Tap the map or search to choose a place.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            if device.isSimulating {
                Button(role: .destructive) {
                    Task {
                        await device.clearLocation()
                        router.toast("Real location restored.")
                    }
                } label: {
                    Label("Restore Real Location", systemImage: "location.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func go(to place: Place) async {
        do {
            try await device.setLocation(place)
            router.toast("Location set to \(place.name).")
        } catch {
            router.toast(error.localizedDescription, error: true)
        }
    }
}

struct SimulatedDot: View {
    var body: some View {
        ZStack {
            Circle().fill(Theme.coral.opacity(0.25)).frame(width: 34, height: 34)
            Circle().fill(.white).frame(width: 18, height: 18)
            Circle().fill(Theme.coral).frame(width: 13, height: 13)
        }
    }
}

struct RouteProgressCard: View {
    let progress: RouteProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(progress.finished ? "Arrived: \(progress.routeName)" : "Playing: \(progress.routeName)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(progress.finished ? "Holding final stop" : "\(Geo.formatDuration(progress.remainingSeconds)) left")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: progress.totalKm > 0 ? progress.travelledKm / progress.totalKm : 1)
                .tint(Theme.coral)
            Text(String(format: "%.2f of %.2f km", progress.travelledKm, progress.totalKm))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct CoordinateEntryView: View {
    var onDone: (Place) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var name = ""

    private var place: Place? {
        guard let lat = Double(latitude.replacingOccurrences(of: ",", with: ".")),
              let lon = Double(longitude.replacingOccurrences(of: ",", with: ".")),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return Place.at(CLLocationCoordinate2D(latitude: lat, longitude: lon),
                        name: name.isEmpty ? "Coordinates" : name)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Latitude (-90 to 90)", text: $latitude).keyboardType(.numbersAndPunctuation)
                TextField("Longitude (-180 to 180)", text: $longitude).keyboardType(.numbersAndPunctuation)
                TextField("Name (optional)", text: $name)
            }
            .navigationTitle("Coordinates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Show") {
                        if let place { onDone(place); dismiss() }
                    }
                    .disabled(place == nil)
                }
            }
        }
    }
}

import MapKit
import SwiftUI

@main
struct WaypointApp: App {
    @StateObject private var store = PlaceStore()
    @StateObject private var device = DeviceService()
    @StateObject private var pairing = PairingService()
    @StateObject private var router = Router()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(device)
                .environmentObject(pairing)
                .environmentObject(router)
                .onAppear { device.store = store }
                .tint(Theme.coral)
        }
    }
}

/// Which tab is showing and which place is selected on the Explore map.
@MainActor
final class Router: ObservableObject {
    enum Tab: Hashable { case explore, favorites, routes, history, setup }
    @Published var tab: Tab = .explore
    @Published var selected: Place?
    @Published var cameraTarget: CLLocationCoordinate2D?
    @Published var message: Banner?

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    func show(_ place: Place) {
        selected = place
        cameraTarget = place.coordinate
        tab = .explore
    }

    func toast(_ text: String, error: Bool = false) {
        message = Banner(text: text, isError: error)
    }
}

enum Theme {
    static let coral = Color(red: 1.0, green: 0.396, blue: 0.278)
    static let green = Color(red: 0.247, green: 0.525, blue: 0.427)
}

struct RootView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var device: DeviceService

    var body: some View {
        TabView(selection: $router.tab) {
            ExploreView()
                .tabItem { Label("Explore", systemImage: "map") }
                .tag(Router.Tab.explore)
            FavoritesView()
                .tabItem { Label("Favorites", systemImage: "star") }
                .tag(Router.Tab.favorites)
            RoutesView()
                .tabItem { Label("Routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                .tag(Router.Tab.routes)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Router.Tab.history)
            SetupView()
                .tabItem { Label("Setup", systemImage: "iphone.gen3") }
                .tag(Router.Tab.setup)
                .badge(device.status == .notPaired ? 1 : 0)
        }
        .overlay(alignment: .top) { BannerView() }
        .onAppear {
            if !device.hasPairingFile { router.tab = .setup }
        }
    }
}

struct BannerView: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        if let message = router.message {
            Text(message.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(message.isError ? Color.red.opacity(0.92) : Theme.green.opacity(0.95), in: Capsule())
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { router.message = nil }
                .task(id: message.id) {
                    try? await Task.sleep(nanoseconds: message.isError ? 6_000_000_000 : 3_000_000_000)
                    if router.message?.id == message.id {
                        withAnimation { router.message = nil }
                    }
                }
        }
    }
}

/// Small status pill used on the map screens.
struct DeviceStatusPill: View {
    @EnvironmentObject private var device: DeviceService
    @EnvironmentObject private var router: Router

    var body: some View {
        Button { router.tab = .setup } label: {
            HStack(spacing: 6) {
                if device.isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(text).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var text: String {
        if device.routeProgress?.finished == false { return "Route playing" }
        if device.isSimulating { return "Simulating" }
        switch device.status {
        case .notPaired: return "Not paired"
        case .disconnected: return "Not connected"
        case .working(let message): return message
        case .connected: return "Connected"
        case .ready: return "Ready"
        case .failed: return "Needs attention"
        }
    }

    private var color: Color {
        if device.isSimulating { return Theme.coral }
        switch device.status {
        case .ready, .connected: return Theme.green
        case .failed, .notPaired: return .red
        default: return .gray
        }
    }
}

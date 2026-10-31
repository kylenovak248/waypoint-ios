import CoreLocation
import Foundation

struct Place: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var detail: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var coordinateText: String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }

    func sameSpot(as other: Place) -> Bool {
        abs(latitude - other.latitude) < 0.000_01 && abs(longitude - other.longitude) < 0.000_01
    }

    static func at(_ coordinate: CLLocationCoordinate2D, name: String = "Dropped pin", detail: String = "") -> Place {
        Place(name: name,
              detail: detail.isEmpty ? String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude) : detail,
              latitude: coordinate.latitude,
              longitude: coordinate.longitude)
    }
}

struct SavedRoute: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var points: [Place]
    var speedKmh: Double

    var distanceKm: Double { Geo.pathLengthKm(points.map(\.coordinate)) }
    var durationSeconds: Double { speedKmh > 0 ? distanceKm / speedKmh * 3600 : 0 }
}

struct HistoryItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case teleport = "Teleport", route = "Route" }
    var id = UUID()
    var place: Place
    var kind: Kind
    var date: Date
}

enum SpeedPreset: Double, CaseIterable, Identifiable {
    case walk = 5, run = 10, bike = 18, car = 50, highway = 100
    var id: Double { rawValue }
    var label: String {
        switch self {
        case .walk: "Walk"
        case .run: "Run"
        case .bike: "Bike"
        case .car: "Car"
        case .highway: "Highway"
        }
    }
}

enum Geo {
    static func distanceKm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6371.0088
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    static func pathLengthKm(_ points: [CLLocationCoordinate2D]) -> Double {
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { $0 + distanceKm($1.0, $1.1) }
    }

    /// Great-circle interpolation, so long legs follow the real shortest path.
    static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
        let t = min(max(t, 0), 1)
        let p1 = a.latitude * .pi / 180, l1 = a.longitude * .pi / 180
        let p2 = b.latitude * .pi / 180, l2 = b.longitude * .pi / 180
        let d = distanceKm(a, b) / 6371.0088
        guard d > 1e-9 else { return a }
        let s1 = sin((1 - t) * d) / sin(d), s2 = sin(t * d) / sin(d)
        let x = s1 * cos(p1) * cos(l1) + s2 * cos(p2) * cos(l2)
        let y = s1 * cos(p1) * sin(l1) + s2 * cos(p2) * sin(l2)
        let z = s1 * sin(p1) + s2 * sin(p2)
        return CLLocationCoordinate2D(latitude: atan2(z, sqrt(x * x + y * y)) * 180 / .pi,
                                      longitude: atan2(y, x) * 180 / .pi)
    }

    /// Position after travelling `km` along the path.
    static func point(along points: [CLLocationCoordinate2D], km: Double) -> CLLocationCoordinate2D? {
        guard let first = points.first else { return nil }
        var remaining = max(km, 0)
        for (a, b) in zip(points, points.dropFirst()) {
            let leg = distanceKm(a, b)
            if remaining <= leg { return interpolate(a, b, leg > 0 ? remaining / leg : 1) }
            remaining -= leg
        }
        return points.last ?? first
    }

    static func parseCoordinates(_ text: String) -> CLLocationCoordinate2D? {
        let numbers = text.replacingOccurrences(of: ";", with: ",")
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { Double($0) }
        guard numbers.count == 2, abs(numbers[0]) <= 90, abs(numbers[1]) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: numbers[0], longitude: numbers[1])
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

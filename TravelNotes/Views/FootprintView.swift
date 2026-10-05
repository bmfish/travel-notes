import SwiftUI
import MapKit
import SwiftData

/// 「足迹」页:暗色地图 + 发光线路 + 底部统计卡,风格参考航旅纵横足迹
struct FootprintView: View {
    @Query(sort: \TicketEntry.date, order: .reverse) private var entries: [TicketEntry]

    var body: some View {
        ZStack(alignment: .bottom) {
            DarkMapView(entries: entries)
                .ignoresSafeArea()
            statsCard
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .navigationTitle("足迹")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: 统计口径

    private var stationCount: Int {
        var names = Set<String>()
        for e in entries {
            if let f = e.fromStation, !f.isEmpty { names.insert(f) }
            if let t = e.toStation, !t.isEmpty { names.insert(t) }
        }
        return names.count
    }

    private var cityCount: Int {
        let dir = StationDirectory.shared
        var cities = Set<String>()
        for e in entries {
            if let f = e.fromStation.flatMap({ dir.resolve($0) }) { cities.insert(f.c) }
            if let t = e.toStation.flatMap({ dir.resolve($0) }) { cities.insert(t.c) }
        }
        return cities.count
    }

    private var statsCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.black.opacity(0.4))
                Text("🚄").font(.system(size: 24))
            }
            .frame(width: 46, height: 46)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                statItem("车站", "\(stationCount)", "个")
                statItem("次数", "\(entries.count)", "次")
                statItem("城市", "\(cityCount)", "个")
                statItem("里程", kmText, "km")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black.opacity(0.55))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
        )
    }

    private func statItem(_ label: String, _ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.65))
            Text(value)
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundColor(footprintGreen)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(unit)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.65))
        }
    }

    private var kmText: String {
        let km = Int(MileageEstimator.totalKm(entries: entries))
        return km >= 10000 ? String(format: "%.1f万", Double(km) / 10000) : "\(km)"
    }
}

let footprintGreen = Color(red: 0.30, green: 0.87, blue: 0.52)

// MARK: - 暗色地图(MKMapView,强制深色外观)

struct DarkMapView: UIViewRepresentable {
    let entries: [TicketEntry]

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.overrideUserInterfaceStyle = .dark
        map.delegate = context.coordinator
        map.showsBuildings = false
        let config = MKStandardMapConfiguration(elevationStyle: .flat)
        config.pointOfInterestFilter = .excludingAll
        config.showsTraffic = false
        map.preferredConfiguration = config
        map.register(StationAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: StationAnnotationView.reuseID)
        context.coordinator.sync(entries: entries, map: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.sync(entries: entries, map: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var signature = ""

        func sync(entries: [TicketEntry], map: MKMapView) {
            let sig = entries.map { "\($0.id.uuidString)|\($0.fromStation ?? "")>\($0.toStation ?? "")" }
                .joined(separator: ";")
            guard sig != signature else { return }
            signature = sig

            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations)

            let dir = StationDirectory.shared
            var allPoints: [CLLocationCoordinate2D] = []
            var stationHits: [String: (station: Station, count: Int)] = [:]

            for e in entries {
                guard let f = e.fromStation.flatMap({ dir.resolve($0) }),
                      let t = e.toStation.flatMap({ dir.resolve($0) }) else { continue }
                // 站名表扩容后部分小站没有坐标(0,0 占位),画弧线会拐到几内亚湾,跳过
                guard f.lat != 0 || f.lng != 0, t.lat != 0 || t.lng != 0 else { continue }
                let color = UIColor(TicketInfo(entry: e).routeColor)
                map.addOverlays(RouteGeometry.arcOverlays(from: f.coord, to: t.coord, color: color))
                allPoints.append(contentsOf: [f.coord, t.coord])
                for name in [e.fromStation, e.toStation] {
                    guard let name, !name.isEmpty, let s = dir.resolve(name) else { continue }
                    if let old = stationHits[name] {
                        stationHits[name] = (s, old.count + 1)
                    } else {
                        stationHits[name] = (s, 1)
                    }
                }
            }
            // 同城多个车站合并为一个点,坐标取乘坐次数最多的那个车站
            var cityBest: [String: (station: Station, count: Int)] = [:]
            for pair in stationHits.values {
                if let old = cityBest[pair.station.c] {
                    if pair.count > old.count { cityBest[pair.station.c] = pair }
                } else {
                    cityBest[pair.station.c] = pair
                }
            }
            for (city, best) in cityBest {
                let a = StationAnnotation(city: city)
                a.coordinate = best.station.coord
                map.addAnnotation(a)
            }

            if allPoints.isEmpty {
                DispatchQueue.main.async {
                    let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 34, longitude: 108),
                                                    span: MKCoordinateSpan(latitudeDelta: 42, longitudeDelta: 42))
                    map.setRegion(region, animated: false)
                }
            } else {
                var rect = MKMapRect.null
                for p in allPoints {
                    let mp = MKMapPoint(p)
                    rect = rect.union(MKMapRect(x: mp.x, y: mp.y, width: 1, height: 1))
                }
                DispatchQueue.main.async {
                    map.setVisibleMapRect(rect,
                                          edgePadding: UIEdgeInsets(top: 130, left: 50, bottom: 250, right: 50),
                                          animated: false)
                }
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? ColoredPolyline {
                let r = MKPolylineRenderer(polyline: line)
                if line.title == "glow" {
                    r.strokeColor = line.base.withAlphaComponent(0.13)
                    r.lineWidth = 8
                    r.lineCap = .round
                } else {
                    r.strokeColor = line.base.withAlphaComponent(0.85)
                    r.lineWidth = 1.6
                    r.lineCap = .round
                }
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is StationAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: StationAnnotationView.reuseID, for: annotation)
            return view
        }
    }
}

// MARK: - 弧线几何

/// 带方向配色的折线
final class ColoredPolyline: MKPolyline {
    var base: UIColor = .systemGreen
}

enum RouteGeometry {
    static func arcOverlays(from: CLLocationCoordinate2D,
                            to: CLLocationCoordinate2D,
                            color: UIColor) -> [ColoredPolyline] {
        let pts = arcPoints(from: from, to: to)
        var glow = ColoredPolyline(coordinates: pts, count: pts.count)
        glow.title = "glow"
        glow.base = color
        var core = ColoredPolyline(coordinates: pts, count: pts.count)
        core.title = "core"
        core.base = color
        return [glow, core]
    }

    /// 两点间的抛物弧:沿垂直方向隆起,统一向北弯,同走廊的正反向线路会重叠成一条
    static func arcPoints(from: CLLocationCoordinate2D,
                          to: CLLocationCoordinate2D,
                          segments: Int = 64) -> [CLLocationCoordinate2D] {
        let dLat = to.latitude - from.latitude
        let dLng = to.longitude - from.longitude
        let dist = max(0.0001, sqrt(dLat * dLat + dLng * dLng))
        let bump = dist * 0.10
        var px = -dLat / dist * bump
        var py = dLng / dist * bump
        if py < 0 { px = -px; py = -py }
        var pts: [CLLocationCoordinate2D] = []
        for i in 0...segments {
            let t = Double(i) / Double(segments)
            let s = sin(.pi * t)
            pts.append(CLLocationCoordinate2D(latitude: from.latitude + dLat * t + py * s,
                                              longitude: from.longitude + dLng * t + px * s))
        }
        return pts
    }
}

// MARK: - 车站标注(发光圆点 + 城市名)

final class StationAnnotation: MKPointAnnotation {
    let city: String
    init(city: String) {
        self.city = city
        super.init()
        title = city
    }
}

final class StationAnnotationView: MKAnnotationView {
    static let reuseID = "StationAnnotationView"

    private let dot = UIView()
    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = MKFeatureDisplayPriority(rawValue: 750)

        dot.backgroundColor = UIColor(footprintGreen)
        dot.layer.cornerRadius = 5
        dot.layer.shadowColor = UIColor(footprintGreen).cgColor
        dot.layer.shadowOpacity = 0.9
        dot.layer.shadowRadius = 5
        dot.layer.shadowOffset = .zero
        dot.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        addSubview(dot)

        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.shadowColor = UIColor.black.withAlphaComponent(0.9)
        label.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(label)

        centerOffset = CGPoint(x: 0, y: 12)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        configure()
    }

    private func configure() {
        guard let a = annotation as? StationAnnotation else { return }
        label.text = a.city
        label.sizeToFit()
        let width = max(24, label.frame.width + 10)
        bounds = CGRect(origin: .zero, size: CGSize(width: width, height: 32))
        dot.frame.origin = CGPoint(x: width / 2 - 5, y: 0)
        label.frame.origin = CGPoint(x: (width - label.frame.width) / 2, y: 13)
    }
}

extension Station {
    var coord: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

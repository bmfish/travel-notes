import Foundation

struct Station: Codable, Hashable {
    /// 站名,如 杭州东
    let n: String
    /// 所属城市,如 杭州
    let c: String
    let lat: Double
    let lng: Double
}

/// 内置站名目录:自动补全 + 里程估算
final class StationDirectory {
    static let shared = StationDirectory()

    let stations: [Station]
    private let byName: [String: Station]
    private let byBase: [String: Station]
    private let byCity: [String: Station]

    init() {
        guard let url = Bundle.main.url(forResource: "Stations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Station].self, from: data) else {
            stations = []
            byName = [:]
            byBase = [:]
            byCity = [:]
            return
        }
        let nameMap = Dictionary(list.map { ($0.n, $0) }, uniquingKeysWith: { a, _ in a })
        let baseMap = Dictionary(list.map { (Self.strip($0.n), $0) }, uniquingKeysWith: { a, _ in a })
        let cityMap = Dictionary(list.map { ($0.c, $0) }, uniquingKeysWith: { a, _ in a })
        stations = list.sorted { $0.n < $1.n }
        byName = nameMap
        byBase = baseMap
        byCity = cityMap
    }

    /// "杭州东" -> "杭州",用于坐标匹配兜底
    static func strip(_ name: String) -> String {
        var s = name
        let suffixes: Set<String> = ["站", "东", "西", "南", "北"]
        while s.count > 1, let last = s.last, suffixes.contains(String(last)) {
            s.removeLast()
        }
        return s
    }

    /// 宽松匹配:全名 -> 去方向后缀 -> 城市名
    func resolve(_ raw: String) -> Station? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let s = byName[name] { return s }
        if let s = byBase[Self.strip(name)] { return s }
        return byCity[name]
    }

    /// 自动补全:前缀优先,再包含匹配
    func suggest(_ raw: String, limit: Int = 6) -> [Station] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let starts = stations.filter { $0.n.hasPrefix(q) || $0.c.hasPrefix(q) }
        let contains = stations.filter {
            !$0.n.hasPrefix(q) && !$0.c.hasPrefix(q) && ($0.n.contains(q) || $0.c.contains(q))
        }
        return Array((starts + contains).prefix(limit))
    }
}

enum MileageEstimator {
    /// 球面直线距离 × 1.25 作为铁路里程粗估
    static func kmBetween(_ a: Station, _ b: Station) -> Double {
        func rad(_ d: Double) -> Double { d * .pi / 180 }
        let dLat = rad(b.lat - a.lat)
        let dLng = rad(b.lng - a.lng)
        let x = sin(dLat / 2) * sin(dLat / 2)
            + cos(rad(a.lat)) * cos(rad(b.lat)) * sin(dLng / 2) * sin(dLng / 2)
        let straight = 2 * 6371.0 * asin(min(1, sqrt(x)))
        return straight * 1.25
    }

    static func totalKm(entries: [TicketEntry]) -> Double {
        var total = 0.0
        for e in entries {
            guard let f = e.fromStation.flatMap({ StationDirectory.shared.resolve($0) }),
                  let t = e.toStation.flatMap({ StationDirectory.shared.resolve($0) }) else { continue }
            total += kmBetween(f, t)
        }
        return total
    }
}

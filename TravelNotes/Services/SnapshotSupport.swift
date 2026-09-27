import SwiftUI
import MapKit
import Darwin

/// 调试辅助:以 `-Snapshots` 启动参数运行时,把核心票面渲染成 PNG
/// 输出到 /tmp 后退出,便于无屏幕权限环境下做视觉检查。
@MainActor
enum SnapshotSupport {
    static var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-Snapshots")
    }

    static func runIfNeeded() {
        if ProcessInfo.processInfo.arguments.contains("-MapSnapshot") {
            runMapSnapshot()
            return
        }
        guard enabled else { return }
        let blue = sampleInfo(skin: .blue)
        let red = sampleInfo(skin: .red)

        render("ticket_blue", BlueTicketFace(info: blue, punchColor: Theme.paperBackground).frame(width: 340))
        render("ticket_red", RedTicketFace(info: red, punchColor: Theme.paperBackground).frame(width: 340))
        render("mini_blue", MiniTicketCard(info: blue, tilt: 0).frame(width: 340))
        render("mini_red", MiniTicketCard(info: red, tilt: 0).frame(width: 340))

        exit(0)
    }

    private static func sampleInfo(skin: TicketSkin) -> TicketInfo {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 20; c.hour = 9; c.minute = 15
        let date = Calendar.current.date(from: c) ?? Date()
        return TicketInfo(
            trainNo: "G1024", from: "杭州东", to: "上海虹桥",
            date: date, departTime: date,
            coach: "12车", seat: "07A号", seatClass: "二等座",
            price: 73, skin: skin
        )
    }

    private static func render(_ name: String, _ view: some View) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.uiImage, let data = image.pngData() {
            try? data.write(to: URL(fileURLWithPath: "/tmp/tn_\(name).png"))
        }
    }

    /// 以 `-MapSnapshot` 运行:挂载足迹地图,等瓦片就绪后截图存盘退出
    private static func runMapSnapshot() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { exit(1) }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

        let map = MKMapView(frame: window.bounds)
        map.overrideUserInterfaceStyle = .dark
        map.showsBuildings = false
        let config = MKStandardMapConfiguration(elevationStyle: .flat)
        config.pointOfInterestFilter = .excludingAll
        config.showsTraffic = false
        map.preferredConfiguration = config
        map.register(StationAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: StationAnnotationView.reuseID)

        // delegate 是弱引用,必须由静态属性持有
        let coordinator = DarkMapView.Coordinator()
        coordinator.sync(entries: SampleData.make(), map: map)
        map.delegate = coordinator

        window.addSubview(map)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        keeper = (window, coordinator)

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            let renderer = UIGraphicsImageRenderer(size: map.bounds.size)
            let image = renderer.image { ctx in
                map.layer.render(in: ctx.cgContext)
            }
            try? image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/tn_map.png"))
            exit(0)
        }
    }

    @MainActor
    private static var keeper: (UIWindow, DarkMapView.Coordinator)?
}

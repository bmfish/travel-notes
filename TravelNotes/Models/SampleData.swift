import Foundation

/// 模拟器演示数据(仅 -UITestSeed 启动参数时使用)
enum SampleData {
    static func make() -> [TicketEntry] {
        func d(_ y: Int, _ m: Int, _ day: Int, _ hh: Int = 9, _ mm: Int = 15) -> Date {
            var c = DateComponents()
            c.year = y; c.month = m; c.day = day; c.hour = hh; c.minute = mm
            return Calendar.current.date(from: c) ?? Date()
        }
        return [
            TicketEntry(
                date: d(2026, 9, 20), departTime: d(2026, 9, 20, 9, 15),
                trainNo: "G1024", fromStation: "杭州东", toStation: "上海虹桥",
                coach: "12车", seat: "07A号", seatClass: "二等座", price: 73, skin: .blue,
                note: "车过嘉兴时下了场太阳雨,窗外整片稻田亮得晃眼。邻座大爷泡了一杯浓茶,跟我聊他年轻时跑船的故事。"
            ),
            TicketEntry(
                date: d(2026, 5, 1), departTime: d(2026, 5, 1, 18, 32),
                trainNo: "K1373", fromStation: "北京", toStation: "南京",
                coach: "05车", seat: "11号下铺", seatClass: "硬卧", price: 156, skin: .red,
                note: "绿皮车晃晃悠悠过一夜,上铺的小孩数了一路隧道。"
            ),
            TicketEntry(
                date: d(2026, 2, 10), departTime: d(2026, 2, 10, 7, 58),
                trainNo: "D2281", fromStation: "广州南", toStation: "厦门北",
                coach: "08车", seat: "03F号", seatClass: "二等座", price: 312, skin: .blue
            ),
            TicketEntry(
                date: d(2025, 10, 2), departTime: d(2025, 10, 2, 13, 6),
                trainNo: "G7419", fromStation: "上海虹桥", toStation: "杭州东",
                seatClass: "一等座", price: 117, skin: .red,
                note: "临时起意的周末,到站才订酒店,深一脚浅一脚也挺好。"
            ),
            TicketEntry(
                date: d(2025, 4, 5), departTime: d(2025, 4, 5, 20, 11),
                trainNo: "Z98", fromStation: "上海", toStation: "北京",
                coach: "09车", seat: "05号上铺", seatClass: "软卧", price: 481, skin: .red
            ),
            TicketEntry(
                date: d(2024, 8, 15), departTime: d(2024, 8, 15, 6, 44),
                trainNo: "T110", fromStation: "北京西", toStation: "上海",
                seatClass: "硬座", price: 177.5, skin: .blue,
                note: "第一次坐十几小时的硬座,天亮时看到芦苇荡,值了。"
            ),
            TicketEntry(
                date: d(2024, 1, 1), departTime: d(2024, 1, 1, 7, 0),
                trainNo: "G1", fromStation: "北京南", toStation: "上海虹桥",
                coach: "03车", seat: "01A号", seatClass: "商务座", price: 1748, skin: .blue,
                note: "元旦的清晨,车厢里安安静静,只有咖啡机在响。"
            )
        ]
    }
}

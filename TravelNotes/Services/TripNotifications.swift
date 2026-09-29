import Foundation
import UserNotifications
import SwiftData

/// 行程本地通知:开车前 2 小时 / 预计开始检票 / 即将停止检票。
/// 12306 不提前公布精确检票时刻,开始/停止检票按实测经验窗口预估(开车前 20/5 分钟)。
/// 只排未来 24 小时内出发的行程,通知总数控制在系统 64 条上限之内。
@MainActor
enum TripNotifications {
    private static let prefix = "trip-notify-"

    static func refresh(context: ModelContext) async {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let limit = start.addingTimeInterval(24 * 3600)
        var fetch = FetchDescriptor<TicketEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < limit },
            sortBy: [SortDescriptor(\.date)])
        fetch.fetchLimit = 12
        guard let entries = try? context.fetch(fetch), !entries.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        guard let granted = try? await center.requestAuthorization(options: [.alert, .sound]),
              granted else { return }

        // 先清掉旧的行程通知再重排,编辑/删除行程后不残留
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        for entry in entries {
            guard let departTime = entry.departTime else { continue }
            // departTime 可能只带时分,统一挂到乘车日期当天
            let comps = cal.dateComponents([.hour, .minute], from: departTime)
            guard let depart = cal.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0,
                                        second: 0, of: entry.date) else { continue }
            let train = entry.trainNo ?? "列车"
            let route = "\(TicketInfo.stationText(entry.fromStation)) → \(TicketInfo.stationText(entry.toStation))"
            let seat = [entry.coach.map { "\($0)车" }, entry.seat].compactMap { $0 }.joined(separator: " ")
            let hhmm = Fmt.clock.string(from: depart)
            let leads: [(String, TimeInterval, String, String)] = [
                ("t120", 2 * 3600, "🚄 2 小时后开车",
                 "\(train) \(hhmm) 开 · \(route)\(seat.isEmpty ? "" : " · \(seat)")"),
                ("t20", 20 * 60, "🔔 预计开始检票",
                 "\(train) \(hhmm) 开 · 请前往候车区,检票口以车站大屏为准"),
                ("t5", 5 * 60, "⏰ 即将停止检票",
                 "\(train) \(hhmm) 开 · 约开车前 5 分钟停止检票,请尽快检票进站"),
            ]
            for (tag, before, title, body) in leads {
                let fire = depart.addingTimeInterval(-before)
                guard fire > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let fireComps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let trigger = UNCalendarNotificationTrigger(dateMatching: fireComps, repeats: false)
                let request = UNNotificationRequest(identifier: "\(prefix)\(entry.id.uuidString)-\(tag)",
                                                    content: content, trigger: trigger)
                _ = try? await center.add(request)
            }
        }
    }
}

import Foundation
import EventKit

/// 行程的「加日历/导出」要素
struct TripPlan {
    let title: String
    let location: String
    let start: Date
    let end: Date
    let notes: String
}

enum TripCalendarError: Error {
    case noPermission
    case noCalendar
}

/// 把车票行程写进系统日历,或导出 .ics 供其它日历 App 导入
enum TripCalendar {

    // MARK: - 组装行程要素

    /// 到达时刻(HH:mm),查经停时刻表;查不到返回 nil
    static func arrivalTime(for entry: TicketEntry) async -> String? {
        guard let code = entry.trainNo, !code.isEmpty, let to = entry.toStation else { return nil }
        if let stops = try? await TrainScheduleService.shared.stops(
            trainNo: code, fromStation: entry.fromStation ?? "",
            toStation: to, date: entry.date),
           let stop = stops.first(where: { TrainLiveService.looseMatch($0.stationName, to) }),
           stop.arriveTime != "----" {
            return hhmm(stop.arriveTime)
        }
        return nil
    }

    static func plan(for entry: TicketEntry, arriveText: String?) -> TripPlan {
        let from = stationName(entry.fromStation)
        let to = stationName(entry.toStation)
        let train = entry.trainNo ?? "行程"
        let start = entry.departTime ?? entry.date
        var end = start.addingTimeInterval(2 * 3600)
        if let arriveText, let t = timeComponents(arriveText) {
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: entry.date)
            comps.hour = t.hour
            comps.minute = t.minute
            if let candidate = Calendar.current.date(from: comps) {
                end = candidate > start ? candidate : candidate.addingTimeInterval(24 * 3600)
            }
        }
        var notes: [String] = []
        if let coach = entry.coach, !coach.isEmpty { notes.append("车厢:\(coach)") }
        if let seat = entry.seat, !seat.isEmpty { notes.append("座位:\(seat)") }
        if let seatClass = entry.seatClass, !seatClass.isEmpty { notes.append("席别:\(seatClass)") }
        if let price = entry.price, price > 0 { notes.append("票价:¥\(price)") }
        notes.append("由高铁笔记添加")
        return TripPlan(title: "\(train) \(from) → \(to)",
                        location: from + "站",
                        start: start,
                        end: end,
                        notes: notes.joined(separator: "\n"))
    }

    // MARK: - 系统日历

    static func addToCalendar(_ plan: TripPlan) async throws {
        let store = EKEventStore()
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = try await store.requestWriteOnlyAccessToEvents()
        } else {
            granted = try await store.requestAccess(to: .event)
        }
        guard granted else { throw TripCalendarError.noPermission }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw TripCalendarError.noCalendar
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = plan.title
        event.location = plan.location
        event.startDate = plan.start
        event.endDate = plan.end
        event.notes = plan.notes
        event.addAlarm(EKAlarm(relativeOffset: -2 * 3600))
        try store.save(event, span: .thisEvent)
    }

    // MARK: - .ics 文件(任何日历 App 都能导入)

    static func icsFile(for plan: TripPlan) throws -> URL {
        let lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//gaotiebiji//TravelNotes//CN",
            "CALSCALE:GREGORIAN",
            "BEGIN:VEVENT",
            "UID:\(UUID().uuidString)@gaotiebiji",
            "DTSTAMP:\(icsDate(Date()))",
            "DTSTART:\(icsDate(plan.start))",
            "DTEND:\(icsDate(plan.end))",
            "SUMMARY:\(icsEscape(plan.title))",
            "LOCATION:\(icsEscape(plan.location))",
            "DESCRIPTION:\(icsEscape(plan.notes))",
            "BEGIN:VALARM",
            "TRIGGER:-PT2H",
            "ACTION:DISPLAY",
            "DESCRIPTION:\(icsEscape(plan.title))",
            "END:VALARM",
            "END:VEVENT",
            "END:VCALENDAR"
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("高铁笔记-\(plan.title.replacingOccurrences(of: " ", with: "")).ics")
        try lines.joined(separator: "\r\n").data(using: .utf8)!.write(to: url)
        return url
    }

    static func copyText(for entry: TicketEntry, plan: TripPlan) -> String {
        var lines = [plan.title,
                     Fmt.cnDate.string(from: entry.date),
                     Fmt.clock.string(from: plan.start) + " 开 · " + Fmt.clock.string(from: plan.end) + " 到"]
        lines.append(plan.notes.replacingOccurrences(of: "由高铁笔记添加", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n")
    }

    // MARK: - 调试钩子:-CalTest 验证日历写入

    static func runSelfTestIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-CalTest") else { return }
        Task {
            let cal = Calendar.current
            let date = cal.date(byAdding: .day, value: 3, to: cal.startOfDay(for: Date()))!
            let start = cal.date(bySettingHour: 8, minute: 25, second: 0, of: date)!
            let entry = TicketEntry(date: date, departTime: start, trainNo: "G1914",
                                    fromStation: "郑州东", toStation: "上海虹桥",
                                    coach: "07", seat: "02F", seatClass: "二等座", price: 471)
            let plan = TripPlan(title: "CALTEST G1914 郑州东 → 上海虹桥",
                                location: "郑州东站", start: start,
                                end: start.addingTimeInterval(4 * 3600 + 57 * 60),
                                notes: "自检事件,可删除")
            do {
                try await addToCalendar(plan)
                print("CALTEST OK 写入日历:\(plan.title)")
                let url = try icsFile(for: plan)
                print("CALTEST ICS \(url.path)")
            } catch {
                print("CALTEST FAIL \(error)")
            }
        }
    }

    // MARK: - 小工具

    private static func stationName(_ s: String?) -> String {
        let name = (s ?? "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "未知站" : (name.hasSuffix("站") ? String(name.dropLast()) : name)
    }

    private static func hhmm(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 4 else { return raw }
        return digits.prefix(2) + ":" + digits.suffix(2)
    }

    private static func timeComponents(_ text: String) -> DateComponents? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return DateComponents(hour: h, minute: m)
    }

    private static func icsDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    private static func icsEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

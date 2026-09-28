import Foundation
import SwiftData

/// 邮件同步引擎:IMAP 拉取订票邮件 → 解析候选票根 → 用户确认后入库
@MainActor
final class MailSyncEngine: ObservableObject {
    static let shared = MailSyncEngine()

    static let keychainService = "com.bmfish.TravelNotes.mail"
    private static let emailKey = "mail.email"
    private static let lastSyncKey = "mail.lastSync"
    /// QQ 邮箱 IMAP
    static let imapHost = "imap.qq.com"
    static let imapPort: UInt16 = 993

    @Published var running = false
    @Published var statusText = "未同步"
    @Published var lastSyncDate: Date? = UserDefaults.standard.object(forKey: MailSyncEngine.lastSyncKey) as? Date

    var storedEmail: String {
        UserDefaults.standard.string(forKey: Self.emailKey) ?? ""
    }

    var hasCredentials: Bool {
        !storedEmail.isEmpty && Keychain.get(service: Self.keychainService, account: storedEmail) != nil
    }

    func saveAccount(email: String, authCode: String) {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        UserDefaults.standard.set(normalized, forKey: Self.emailKey)
        Keychain.set(authCode, service: Self.keychainService, account: normalized)
    }

    func clearAccount() {
        let email = storedEmail
        if !email.isEmpty { Keychain.delete(service: Self.keychainService, account: email) }
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        UserDefaults.standard.removeObject(forKey: Self.lastSyncKey)
        lastSyncDate = nil
        statusText = "未同步"
    }

    /// 打开 App 时自动同步:已配置且距上次同步超过 1 天
    func autoSyncIfNeeded(context: ModelContext) {
        let debug = ProcessInfo.processInfo.arguments.contains("-MailUser")
        if debug { Self.trace("autoSync: hasCred=\(hasCredentials) running=\(running) last=\(lastSyncDate.map { "\($0)" } ?? "nil")") }
        guard hasCredentials, !running else { return }
        if let last = lastSyncDate, Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
        if debug { Self.trace("autoSync: starting sync") }
        Task { await sync(context: context) }
    }

    static func trace(_ line: String) {
        guard ProcessInfo.processInfo.arguments.contains("-MailUser") else { return }
        let stamped = "\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) \(line)\n"
        // 沙盒里绝对 /tmp 不可写,落到临时目录
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tn_trace.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? stamped.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: 同步主流程

    /// fullHistory = true 时忽略上次同步时间,重新拉取全部历史(用于解析规则升级后补数据)
    func sync(context: ModelContext, fullHistory: Bool = false) async {
        guard !running else { return }
        let email = storedEmail
        guard let authCode = Keychain.get(service: Self.keychainService, account: email), !email.isEmpty else {
            statusText = "请先填写邮箱和授权码"
            return
        }

        running = true
        defer { running = false }
        Self.trace("sync: begin")
        do {
            let server = Self.server()
            statusText = "连接 \(server.host)…"
            Self.trace("sync: connecting")
            var client = try await Self.openSession(email: email, authCode: authCode)
            defer { client.disconnect() }
            var currentFolder: String?
            var reconnects = 0

            func ensureSelected(_ c: IMAPClient, _ folder: String) async throws {
                guard currentFolder != folder else { return }
                _ = try await c.command("SELECT \"\(folder)\"")
                currentFolder = folder
            }

            /// 网络闪断/服务器掐线时自动重连续传(全量同步传输量大,移动端尤其容易被掐)
            func resilient<T>(_ what: String, _ body: (IMAPClient) async throws -> T) async throws -> T {
                while true {
                    do { return try await body(client) }
                    catch {
                        guard Self.isTransient(error), reconnects < 6 else { throw error }
                        reconnects += 1
                        Self.trace("reconnect #\(reconnects) after \(what): \(error)")
                        statusText = "连接中断,自动重连…(\(reconnects)/6)"
                        client.disconnect()
                        currentFolder = nil
                        client = try await Self.openSession(email: email, authCode: authCode)
                    }
                }
            }

            statusText = "打开邮箱…"

            // 阶段一:多文件夹扫描 —— 扫全部文件夹(老邮件可能被归档到自建文件夹,名字里不一定带 12306)
            var mails: [FetchedMail] = []
            var folders = ["INBOX"]
            let listRecords = try await resilient("list") { c in try await c.command("LIST \"\" \"*\"") }
            let listRegex = try? NSRegularExpression(pattern: "\"([^\"]+)\"\\s*$")
            for record in listRecords where record.text.hasPrefix("* LIST") {
                guard !record.text.contains("\\NoSelect"),
                      let regex = listRegex,
                      let match = regex.firstMatch(in: record.text, range: NSRange(record.text.startIndex..., in: record.text)),
                      let range = Range(match.range(at: 1), in: record.text) else { continue }
                let name = String(record.text[range])
                if name != "INBOX", !folders.contains(name) { folders.append(name) }
            }
            Self.trace("folders=\(folders.joined(separator: ","))")

            // 首次同步(无上次时间)与全量模式都覆盖 2010 年以来全部邮件;日常为增量
            let since = (fullHistory || lastSyncDate == nil)
                ? "01-Jan-2010"
                : Self.imapDate(lastSyncDate!)

            for (index, folder) in folders.enumerated() {
                let folderLabel = folder == "INBOX" ? "收件箱" : folder
                statusText = "扫描 \(folderLabel)(\(index + 1)/\(folders.count))…"
                do {
                    let uids = try await resilient("uids \(folder)") { c in
                        try await ensureSelected(c, folder)
                        return try await Self.discoverUIDs(c, folder: folder, since: since, fullHistory: fullHistory)
                    }
                    guard !uids.isEmpty else { continue }
                    let fetched = try await resilient("fetch \(folder)") { c in
                        try await ensureSelected(c, folder)
                        return try await Self.fetchMails(c, folder: folder, uids: uids) { done, total in
                            Task { @MainActor in self.statusText = "拉取邮件 \(done)/\(total)…" }
                        }
                    }
                    mails.append(contentsOf: fetched)
                    Self.trace("folder \(folder) fetched=\(fetched.count)")
                } catch {
                    Self.trace("folder \(folder) failed: \(error)")
                    continue
                }
            }
            mails.sort { ($0.mailDate ?? .distantPast) < ($1.mailDate ?? .distantPast) }

            let ownerSetting = UserDefaults.standard.string(forKey: "mail.owner")
            let owner = (ownerSetting?.isEmpty == false) ? ownerSetting : nil

            // 阶段二:退票/退单邮件 → 已退票行程集合
            var refundKeys = Set<String>()
            for mail in mails where mail.isRefund {
                for ticket in TicketMailParser.parse(subject: mail.subject, bodyText: mail.bodyText, owner: owner, mailDate: mail.mailDate) {
                    refundKeys.insert(Self.tripKey(trainNo: ticket.trainNo, from: ticket.fromStation,
                                                   to: ticket.toStation, date: ticket.date))
                }
            }
            Self.trace("refund keys=\(refundKeys.count)")

            // 阶段三:改签处理 —— 同一订单只保留最后一次改签的新票,改签前的原票作废
            var lastChangeByOrder: [String: FetchedMail] = [:]
            for mail in mails where mail.isChange {
                if let order = mail.orderNumber {
                    lastChangeByOrder[order] = mail
                }
            }
            var changeValidKeys = Set<String>()
            for (order, mail) in lastChangeByOrder {
                for ticket in TicketMailParser.parse(subject: mail.subject, bodyText: mail.bodyText, owner: owner, mailDate: mail.mailDate) {
                    changeValidKeys.insert(Self.tripKey(trainNo: ticket.trainNo, from: ticket.fromStation,
                                                        to: ticket.toStation, date: ticket.date))
                }
            }
            var invalidatedKeys = Set<String>()
            for mail in mails where !mail.isChange && !mail.isRefund {
                // 该订单后来改签过,这封邮件描述的是改签前的原票 → 作废
                guard let order = mail.orderNumber, lastChangeByOrder[order] != nil else { continue }
                for ticket in TicketMailParser.parse(subject: mail.subject, bodyText: mail.bodyText, owner: owner, mailDate: mail.mailDate) {
                    invalidatedKeys.insert(Self.tripKey(trainNo: ticket.trainNo, from: ticket.fromStation,
                                                        to: ticket.toStation, date: ticket.date))
                }
            }
            Self.trace("change orders=\(lastChangeByOrder.count) invalidated=\(invalidatedKeys.count) valid=\(changeValidKeys.count)")

            // 阶段四:购票/改签/候补兑现邮件 → 候选票根
            var newCount = 0
            var knownTripKeys = Self.existingTripKeys(context: context)
            for mail in mails {
                guard !mail.isRefund else { continue }
                if mail.isChange {
                    // 同订单多次改签,只有最后一次的新票有效
                    guard let order = mail.orderNumber, lastChangeByOrder[order]?.uid == mail.uid else { continue }
                }
                for ticket in TicketMailParser.parse(subject: mail.subject, bodyText: mail.bodyText, owner: owner, mailDate: mail.mailDate) {
                    let tripKey = Self.tripKey(trainNo: ticket.trainNo, from: ticket.fromStation,
                                               to: ticket.toStation, date: ticket.date)
                    guard !knownTripKeys.contains(tripKey) else { continue }
                    guard !refundKeys.contains(tripKey) else { continue }
                    if invalidatedKeys.contains(tripKey) && !changeValidKeys.contains(tripKey) { continue }
                    knownTripKeys.insert(tripKey)
                    let candidate = MailCandidate(
                        messageId: "mid-\(tripKey)",
                        date: ticket.date,
                        trainNo: ticket.trainNo,
                        fromStation: ticket.fromStation,
                        toStation: ticket.toStation,
                        departTimeText: ticket.departTimeText,
                        coach: ticket.coach,
                        seat: ticket.seat,
                        seatClass: ticket.seatClass,
                        price: ticket.price,
                        passenger: ticket.passenger
                    )
                    context.insert(candidate)
                    newCount += 1
                }
                try? context.save()
            }
            markSynced()
            statusText = newCount > 0 ? "同步完成,新增 \(newCount) 条待确认票根" : "同步完成,没有新的候选票根"
        } catch {
            statusText = "同步失败:\(error.localizedDescription)"
        }
    }

    // MARK: 拉取与解码(sync 与自检共用同一路径,自检测的就是真实代码)

    struct FetchedMail: Sendable {
        let uid: String
        let folder: String
        let mailDate: Date?
        let subject: String
        let bodyText: String
        let orderNumber: String?
        let isRefund: Bool
        let isChange: Bool
    }

    /// 邮件 UID 发现:增量走 SEARCH;全量不依赖 SEARCH(老邮件 QQ 的 SEARCH 可能查不到),
    /// 按 UID 范围拉头部自己筛发件人/主题
    nonisolated static func discoverUIDs(_ client: IMAPClient, folder: String, since: String, fullHistory: Bool) async throws -> [String] {
        if !fullHistory {
            let records = try await client.command("UID SEARCH SINCE \(since) FROM \"12306\"")
            return parseSearchRecords(records)
        }
        let allRecords = try await client.command("UID FETCH 1:* (UID)", timeout: 90)
        let allUIDs = allRecords.compactMap { extractUID($0.text) }
        var kept: [String] = []
        for chunk in chunked(allUIDs, size: 50) {
            let records = try await client.command(
                "UID FETCH \(chunk.joined(separator: ",")) (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)])",
                timeout: 90)
            for record in records where record.text.contains("FETCH") {
                guard let raw = record.literals.first, let uid = extractUID(record.text) else { continue }
                let subject = MIME.decodeEncodedWords(extractHeader("subject", raw: raw) ?? "")
                let from = MIME.decodeEncodedWords(extractHeader("from", raw: raw) ?? "")
                let isRefundOrChange = subject.contains("退票") || subject.contains("退单") || subject.contains("改签")
                if isRefundOrChange || TicketMailParser.looksLikeTicketMail(from: from, subject: subject) {
                    kept.append(uid)
                }
            }
        }
        return kept
    }

    /// 批量拉取完整邮件;解码放后台线程,全量同步几百封时不把 UI 卡死
    nonisolated static func fetchMails(_ client: IMAPClient, folder: String, uids: [String],
                                       progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async throws -> [FetchedMail] {
        var result: [FetchedMail] = []
        var done = 0
        for chunk in chunked(uids, size: 20) {
            let records = try await client.command("UID FETCH \(chunk.joined(separator: ",")) (BODY.PEEK[])", timeout: 90)
            done += chunk.count
            progress(done, uids.count)
            let decoded = await Task.detached(priority: .userInitiated) {
                decodeRecords(records, folder: folder)
            }.value
            result.append(contentsOf: decoded)
        }
        return result
    }

    /// 解码 + 筛选一批 FETCH 响应(纯 CPU,放后台线程)
    nonisolated static func decodeRecords(_ records: [IMAPRecord], folder: String) -> [FetchedMail] {
        var out: [FetchedMail] = []
        for record in records where record.text.contains("FETCH") {
            guard let raw = record.literals.first else { continue }
            let subject = MIME.decodeEncodedWords(extractHeader("subject", raw: raw) ?? "")
            let from = MIME.decodeEncodedWords(extractHeader("from", raw: raw) ?? "")
            // 退票/退单/改签邮件也要收集(分别用于退票集合与改签原票作废)
            let isRefund = subject.contains("退票") || subject.contains("退单")
            let isChange = subject.contains("改签")
            let bodyText = MIME.stripHTML(MIME.extractBody(raw: raw))
            // 12306 也发营销邮件(同样带车次站名),必须像"购票通知"才收,否则拼出没去过的假行程
            guard isRefund || isChange ||
                    (TicketMailParser.looksLikeTicketMail(from: from, subject: subject)
                     && TicketMailParser.looksLikePurchase(subject: subject, bodyText: bodyText)) else { continue }
            out.append(FetchedMail(uid: extractUID(record.text) ?? "-",
                                   folder: folder,
                                   mailDate: extractMailDate(raw, formatter: mailDateFormatter()),
                                   subject: subject,
                                   bodyText: bodyText,
                                   orderNumber: extractOrderNumber(bodyText),
                                   isRefund: isRefund,
                                   isChange: isChange))
        }
        return out
    }

    nonisolated static func mailDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss ZZZZZ"
        return f
    }

    // MARK: 自检(仅 -MailSyncTest 启动参数;支持本地 mock 或真实 QQ 邮箱)

    static func runSelfTestIfNeeded() async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-MailSyncTest") else { return }
        var lines: [String] = []
        var fetched: [FetchedMail] = []
        do {
            let host = Self.value(of: "-MailHost", in: args) ?? "imap.qq.com"
            let defaultPort = host == "127.0.0.1" ? "8025" : "993"
            let port = UInt16(Self.value(of: "-MailPort", in: args) ?? defaultPort) ?? 993
            let useTLS = host != "127.0.0.1"
            let user = Self.value(of: "-MailUser", in: args) ?? "test@qq.com"
            let pass = Self.value(of: "-MailPass", in: args) ?? "authcode123"

            let client = IMAPClient()
            try await client.connect(host: host, port: port, useTLS: useTLS)
            lines.append("connected host=\(host) tls=\(useTLS)")
            _ = try await client.command("ID (\"name\" \"TrainTicketDiary\" \"version\" \"1.0\")")
            _ = try await client.command("LOGIN \"\(Self.escape(user))\" \"\(Self.escape(pass))\"")
            lines.append("login ok")

            // 与 sync 完全一致的路径:全部文件夹 → 全量 UID 头部筛选 → 批量拉取解码
            var folders = ["INBOX"]
            let listRecords = try await client.command("LIST \"\" \"*\"")
            let listRegex = try? NSRegularExpression(pattern: "\"([^\"]+)\"\\s*$")
            for record in listRecords where record.text.hasPrefix("* LIST") {
                guard !record.text.contains("\\NoSelect"),
                      let regex = listRegex,
                      let match = regex.firstMatch(in: record.text, range: NSRange(record.text.startIndex..., in: record.text)),
                      let range = Range(match.range(at: 1), in: record.text) else { continue }
                let name = String(record.text[range])
                if name != "INBOX", !folders.contains(name) { folders.append(name) }
            }
            lines.append("folders=\(folders.joined(separator: ","))")

            for folder in folders {
                _ = try await client.command("SELECT \"\(folder)\"")
                let uids = try await Self.discoverUIDs(client, folder: folder, since: "01-Jan-2010", fullHistory: true)
                lines.append("folder \(folder) candidate-uids=\(uids.joined(separator: ","))")
                fetched.append(contentsOf: try await Self.fetchMails(client, folder: folder, uids: uids) { _, _ in })
            }
            client.disconnect()

            for mail in fetched {
                lines.append("--- \(mail.folder) uid=\(mail.uid) subject=\(mail.subject) date=\(mail.mailDate.map { "\($0)" } ?? "nil")")
                let tickets = TicketMailParser.parse(subject: mail.subject, bodyText: mail.bodyText, mailDate: mail.mailDate)
                for t in tickets {
                    lines.append("    \(t.trainNo ?? "?") \(t.fromStation ?? "?")→\(t.toStation ?? "?") \(t.date.map { Fmt.dotDate.string(from: $0) } ?? "?") \(t.departTimeText ?? "?") \(t.seatClass ?? "?") \(t.price.map { String($0) } ?? "?")")
                }
            }

            // 本地 mock(mock_imap.py)的预期结果,直接给端到端结论
            if host == "127.0.0.1" {
                let tickets = fetched.flatMap {
                    TicketMailParser.parse(subject: $0.subject, bodyText: $0.bodyText, mailDate: $0.mailDate)
                }
                func check(_ name: String, _ ok: Bool) {
                    lines.append((ok ? "E2EPASS " : "E2EFAIL ") + name)
                }
                let day2013 = Calendar.current.date(from: DateComponents(year: 2013, month: 4, day: 29))
                check("old.T164", tickets.contains {
                    $0.trainNo == "T164" && $0.fromStation == "上海" && $0.toStation == "郑州" && $0.date == day2013
                })
                check("new.G4098", tickets.contains {
                    $0.trainNo == "G4098" && $0.fromStation == "郑州东" && $0.toStation == "上海虹桥"
                })
                check("promo.blocked", !tickets.contains {
                    $0.trainNo == "C1234" || $0.fromStation == "武汉" || $0.toStation == "汉口"
                })
            }
        } catch {
            lines.append("ERROR: \(error.localizedDescription)")
        }
        let out = lines.joined(separator: "\n")
        try? out.write(to: URL(fileURLWithPath: "/tmp/tn_sync.txt"), atomically: true, encoding: .utf8)
        try? out.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("tn_sync.txt"),
                       atomically: true, encoding: .utf8)
        exit(0)
    }

    private static func value(of key: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// 调试:-MailHost/-MailPort 覆盖服务器(配合 scripts/mock_imap.py 本地验证);127.0.0.1 不走 TLS
    private static func server() -> (host: String, port: UInt16, tls: Bool) {
        let args = ProcessInfo.processInfo.arguments
        let host = value(of: "-MailHost", in: args) ?? imapHost
        let port = UInt16(value(of: "-MailPort", in: args) ?? "") ?? imapPort
        return (host, port, host != "127.0.0.1" && port != 8025)
    }

    /// 建立连接 + ID + LOGIN;连接失败自动重试 3 次(移动端网络闪断常见)
    private static func openSession(email: String, authCode: String) async throws -> IMAPClient {
        let server = server()
        var lastError: Error = IMAPError.disconnected
        for attempt in 1...3 {
            let client = IMAPClient()
            do {
                trace("connect \(server.host):\(server.port) attempt \(attempt)")
                try await client.connect(host: server.host, port: server.port, useTLS: server.tls)
                // QQ 邮箱要求在登录前发送 ID 命令表明客户端身份
                _ = try await client.command("ID (\"name\" \"TrainTicketDiary\" \"version\" \"1.0\")")
                _ = try await client.command("LOGIN \"\(escape(email))\" \"\(escape(authCode))\"")
                return client
            } catch {
                lastError = error
                client.disconnect()
                if let e = error as? IMAPError, case .bad = e { throw error } // 账号被拒,重试无意义
                if attempt < 3 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
        throw lastError
    }

    /// 网络/连接类错误可以重连续传;协议拒绝等错误重试无意义
    private static func isTransient(_ error: Error) -> Bool {
        guard let e = error as? IMAPError else { return true }
        switch e {
        case .connection, .disconnected, .timeout, .notConnected: return true
        case .bad, .parse: return false
        }
    }

    // MARK: 工具

    private func markSynced() {
        lastSyncDate = Date()
        UserDefaults.standard.set(Date(), forKey: Self.lastSyncKey)
    }

    private static func existingMessageIDs(context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<MailCandidate>()
        return (try? context.fetch(descriptor).map(\.messageId))?.reduce(into: Set()) { $0.insert($1) } ?? []
    }

    /// 跨邮件内容去重:同一车次+区间+日期只保留一条候选
    private static func existingTripKeys(context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<MailCandidate>()
        let all = (try? context.fetch(descriptor)) ?? []
        return Set(all.map { tripKey(trainNo: $0.trainNo, from: $0.fromStation, to: $0.toStation, date: $0.date) })
    }

    static func tripKey(trainNo: String?, from: String?, to: String?, date: Date?) -> String {
        let dateText = date.map { Fmt.dotDate.string(from: $0) } ?? "?"
        return "\(trainNo ?? "?")|\(from ?? "?")|\(to ?? "?")|\(dateText)"
    }

    /// 批量导入:所有未导入候选按解析结果直接建票根,返回导入数量
    @MainActor
    static func importAllCandidates(context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<MailCandidate>()
        let pending = ((try? context.fetch(descriptor)) ?? []).filter { !$0.imported }
        var count = 0
        for candidate in pending {
            var departTime: Date?
            if let timeText = candidate.departTimeText {
                let parts = timeText.split(separator: ":").compactMap { Int($0) }
                if parts.count >= 2 {
                    departTime = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0,
                                                       of: candidate.date ?? Date())
                }
            }
            let entry = TicketEntry(
                date: candidate.date ?? Date(),
                departTime: departTime,
                trainNo: candidate.trainNo,
                fromStation: candidate.fromStation,
                toStation: candidate.toStation,
                coach: candidate.coach,
                seat: candidate.seat,
                seatClass: candidate.seatClass,
                price: candidate.price,
                skin: .blue
            )
            entry.passenger = candidate.passenger
            context.insert(entry)
            candidate.imported = true
            count += 1
        }
        try? context.save()
        return count
    }

    /// 解析邮件 Date 头(用于跨文件夹的时序排序)
    nonisolated static func extractMailDate(_ raw: Data, formatter: DateFormatter) -> Date? {
        guard let line = extractHeader("date", raw: raw) else { return nil }
        return formatter.date(from: line) ?? formatter.date(from: line.replacingOccurrences(of: "  ", with: " "))
    }

    /// 从正文提取 12306 订单号码,用于关联改签前后的邮件
    nonisolated static func extractOrderNumber(_ bodyText: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "订单号码\\s*([A-Z0-9]{6,16})") else { return nil }
        guard let match = regex.firstMatch(in: bodyText, range: NSRange(bodyText.startIndex..., in: bodyText)),
              let range = Range(match.range(at: 1), in: bodyText) else { return nil }
        return String(bodyText[range])
    }

    /// 从 FETCH 响应头里取 UID
    nonisolated static func extractUID(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "UID (\\d+)"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    nonisolated static func chunked(_ array: [String], size: Int) -> [[String]] {
        guard size > 0 else { return [array] }
        return stride(from: 0, to: array.count, by: size).map {
            Array(array[$0..<min($0 + size, array.count)])
        }
    }

    /// IMAP quoted string 转义
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// IMAP 日期:dd-Mon-yyyy
    static func imapDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MMM-yyyy"
        return formatter.string(from: date).uppercased()
    }

    /// 从 "UID SEARCH 101 102" 记录中取出 UID 列表
    nonisolated static func parseSearchRecords(_ records: [IMAPRecord]) -> [String] {
        guard let search = records.first(where: { $0.text.hasPrefix("* SEARCH") }) else { return [] }
        return search.text
            .split(separator: " ")
            .dropFirst(2)
            .filter { $0.allSatisfy(\.isNumber) }
            .map(String.init)
    }

    /// 从原始邮件中提取单个头部字段(先做折叠行展开)
    nonisolated static func extractHeader(_ name: String, raw: Data) -> String? {
        guard let headerEnd = MIME.headerEnd(in: raw) else { return nil }
        let headerData = raw.subdata(in: raw.startIndex..<headerEnd.lowerBound)
        let headers = String(decoding: headerData, as: UTF8.self)
            .replacingOccurrences(of: "\r\n ", with: " ")
            .replacingOccurrences(of: "\r\n\t", with: " ")
            .replacingOccurrences(of: "\n ", with: " ")
        for line in headers.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if lower.hasPrefix(name + ":") {
                return String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

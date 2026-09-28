import Foundation
import Network

enum IMAPError: LocalizedError {
    case notConnected
    case connection(Error)
    case timeout
    case disconnected
    case bad(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "尚未连接服务器"
        case .connection: return "网络连接中断,请检查网络后重试"
        case .timeout: return "连接超时"
        case .disconnected: return "连接已断开"
        case .bad(let line): return "服务器拒绝:\(line)"
        case .parse(let s): return "响应解析失败:\(s)"
        }
    }
}

/// IMAP 响应中的一条逻辑记录:可能内嵌 literal 字节段
struct IMAPRecord {
    /// 行文本,literal 位置用占位符 \u{0}N\u{0} 表示
    var text: String
    var literals: [Data]

    func literal(_ i: Int) -> Data? {
        guard i < literals.count else { return nil }
        return literals[i]
    }
}

/// 极简 IMAP4rev1 客户端,只覆盖同步邮件所需:ID/LOGIN/SELECT/SEARCH/FETCH/LOGOUT
final class IMAPClient: @unchecked Sendable {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "imap.client")
    private var buffer = Data()
    private var tagIndex = 0

    // MARK: 连接

    func connect(host: String, port: UInt16, useTLS: Bool = true) async throws {
        let params = useTLS ? NWParameters.tls : NWParameters()
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port) ?? 993,
                                using: params)
        connection = conn
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            // 连接建立也要有超时:网络异常时 NWConnection 可能一直停在 preparing
            let timer = makeTimeoutTimer(30) {
                guard !resumed else { return }
                resumed = true
                conn.cancel()
                cont.resume(throwing: IMAPError.timeout)
            }
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    timer.cancel()
                    cont.resume()
                case .failed(let error):
                    resumed = true
                    timer.cancel()
                    cont.resume(throwing: IMAPError.connection(error))
                case .cancelled:
                    resumed = true
                    timer.cancel()
                    cont.resume(throwing: IMAPError.disconnected)
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        let greeting = try await readRecord(timeout: 20)
        guard greeting.text.hasPrefix("*") else { throw IMAPError.parse(greeting.text) }
    }

    func disconnect() {
        // 尽力发送 LOGOUT,然后直接断开
        connection?.send(content: "Z99 LOGOUT\r\n".data(using: .utf8), completion: .contentProcessed { _ in })
        connection?.forceCancel()
        connection = nil
    }

    // MARK: 命令

    @discardableResult
    func command(_ cmd: String, timeout: TimeInterval = 30) async throws -> [IMAPRecord] {
        guard connection != nil else { throw IMAPError.notConnected }
        tagIndex += 1
        let tag = "A\(tagIndex)"
        try await send("\(tag) \(cmd)\r\n")

        var records: [IMAPRecord] = []
        var finalText: String?
        while true {
            let record = try await readRecord(timeout: timeout)
            if record.text.hasPrefix("\(tag) ") {
                finalText = record.text
                break
            }
            records.append(record)
        }
        guard let finalText, finalText.contains(" OK") else {
            throw IMAPError.bad(finalText ?? "no response")
        }
        return records
    }

    // MARK: 发送

    private func send(_ text: String) async throws {
        guard let conn = connection else { throw IMAPError.notConnected }
        let data = Data(text.utf8)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            let timer = makeTimeoutTimer(30) {
                guard !done else { return }
                done = true
                cont.resume(throwing: IMAPError.timeout)
            }
            conn.send(content: data, completion: .contentProcessed { error in
                guard !done else { return }
                done = true
                timer.cancel()
                if let error {
                    cont.resume(throwing: IMAPError.connection(error))
                } else {
                    cont.resume()
                }
            })
        }
    }

    // MARK: 接收

    /// 读一行(到 CRLF),若行尾是 {N} 则继续读取 N 字节 literal 并拼进同一条记录
    private func readRecord(timeout: TimeInterval = 30) async throws -> IMAPRecord {
        var text = ""
        var literals: [Data] = []
        while true {
            let lineData = try await readLine(timeout: timeout)
            if let size = literalSize(lineData) {
                // 行尾 {N}:literal
                let head = lineData.prefix(lineData.count - literalSuffixLength(lineData))
                text += Self.decodeUTF8Lossy(head)
                text += "\u{0}\(literals.count)\u{0}"
                let literal = try await readExact(size, timeout: timeout)
                literals.append(literal)
                // literal 后面还有行尾(可能是 ") 或 CRLF),继续循环拼行
            } else {
                text += Self.decodeUTF8Lossy(lineData)
                return IMAPRecord(text: text, literals: literals)
            }
        }
    }

    private func literalSize(_ data: Data) -> Int? {
        guard data.count >= 3, data[data.count - 1] == 125 else { return nil } // '}'
        var i = data.count - 2
        var digits = 0
        var value = 0
        while i >= 0, data[i] >= 48, data[i] <= 57 { // '0'...'9'
            value = value + (Int(data[i]) - 48) * Int(pow(10, Double(digits)))
            digits += 1
            i -= 1
        }
        guard digits > 0, i >= 0, data[i] == 123 else { return nil } // '{'
        return value
    }

    private func literalSuffixLength(_ data: Data) -> Int {
        var i = data.count - 2
        while i >= 0, data[i] >= 48, data[i] <= 57 { i -= 1 }
        return data.count - 1 - i // "{123...}"
    }

    private func readLine(timeout: TimeInterval) async throws -> Data {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            }
            let chunk = try await receiveOnce(timeout: timeout)
            buffer.append(chunk)
        }
    }

    private func readExact(_ count: Int, timeout: TimeInterval) async throws -> Data {
        while buffer.count < count {
            let chunk = try await receiveOnce(timeout: timeout)
            buffer.append(chunk)
        }
        let end = buffer.startIndex + count
        let out = buffer.subdata(in: buffer.startIndex..<end)
        buffer.removeSubrange(buffer.startIndex..<end)
        return out
    }

    private func receiveOnce(timeout: TimeInterval) async throws -> Data {
        guard let conn = connection else { throw IMAPError.notConnected }
        return try await withCheckedThrowingContinuation { cont in
            var done = false
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak conn] in
                guard !done else { return }
                done = true
                conn?.forceCancel()
                cont.resume(throwing: IMAPError.timeout)
            }
            timer.resume()
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                guard !done else { return }
                done = true
                timer.cancel()
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if let error {
                    cont.resume(throwing: IMAPError.connection(error))
                } else {
                    cont.resume(throwing: IMAPError.disconnected)
                }
            }
        }
    }

    private func makeTimeoutTimer(_ seconds: TimeInterval, _ fire: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { fire() }
        timer.resume()
        return timer
    }

    private static func decodeUTF8Lossy(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }
}

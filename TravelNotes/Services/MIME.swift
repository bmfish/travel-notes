import Foundation

/// 极简 MIME 解码:只覆盖解析订票邮件所需
enum MIME {
    /// RFC 2047 编码头(=?UTF-8?B?...?=)解码
    static func decodeEncodedWords(_ input: String) -> String {
        let pattern = "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?="
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        var out = ""
        var cursor = input.startIndex
        let full = NSRange(input.startIndex..., in: input)
        regex.enumerateMatches(in: input, range: full) { match, _, _ in
            guard let match,
                  let range = Range(match.range, in: input) else { return }
            out += input[cursor..<range.lowerBound]
            let charset = String(input[Range(match.range(at: 1), in: input)!])
            let encoding = String(input[Range(match.range(at: 2), in: input)!])
            let payload = String(input[Range(match.range(at: 3), in: input)!])
            var decoded = ""
            if encoding.uppercased() == "B" {
                if let data = Data(base64Encoded: payload.replacingOccurrences(of: " ", with: "")) {
                    decoded = decode(data, charset: charset)
                }
            } else {
                decoded = decodeQuotedPrintableText(payload, charset: charset)
            }
            out += decoded
            cursor = range.upperBound
        }
        out += input[cursor...]
        return out
    }

    private static func decodeQuotedPrintableText(_ payload: String, charset: String) -> String {
        var bytes: [UInt8] = []
        let chars = Array(payload.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "=", i + 2 < chars.count,
               let hi = hexValue(chars[i + 1]), let lo = hexValue(chars[i + 2]) {
                bytes.append(UInt8(hi * 16 + lo))
                i += 3
            } else if c == "_" {
                bytes.append(32)
                i += 1
            } else {
                for byte in String(c).utf8 { bytes.append(byte) }
                i += 1
            }
        }
        return decode(Data(bytes), charset: charset)
    }

    private static func hexValue(_ c: Unicode.Scalar) -> Int? {
        switch c {
        case "0"..."9": return Int(c.value - 48)
        case "a"..."f": return Int(c.value - 87)
        case "A"..."F": return Int(c.value - 55)
        default: return nil
        }
    }

    /// 按字符集解码;中文邮件常见 gb2312/gbk 走 GB18030
    static func decode(_ data: Data, charset: String) -> String {
        let lower = charset.lowercased()
        let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if lower.contains("gb") || lower.contains("936") {
            if let s = String(data: data, encoding: gbEncoding) {
                return s
            }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        // 老邮件常见裸 GB2312 字节流却没声明 charset,UTF-8 解不开时按 GB18030 兜底
        if let s = String(data: data, encoding: gbEncoding) { return s }
        return String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    /// 解码 quoted-printable 字节流(处理软换行 =\r\n)
    static func decodeQuotedPrintable(_ data: Data) -> Data {
        var out: [UInt8] = []
        var i = 0
        let bytes = [UInt8](data)
        while i < bytes.count {
            let b = bytes[i]
            if b == 61, i + 2 < bytes.count,
               let hi = hexByte(bytes[i + 1]), let lo = hexByte(bytes[i + 2]) {
                out.append(UInt8(hi * 16 + lo))
                i += 3
            } else if b == 61, i + 2 < bytes.count,
                      bytes[i + 1] == 13, bytes[i + 2] == 10 {
                i += 3 // 软换行
            } else if b == 61, i + 1 < bytes.count,
                      bytes[i + 1] == 10 {
                i += 2
            } else {
                out.append(b)
                i += 1
            }
        }
        return Data(out)
    }

    private static func hexByte(_ b: UInt8) -> Int? {
        switch b {
        case 48...57: return Int(b - 48)
        case 65...70: return Int(b - 55)
        case 97...102: return Int(b - 87)
        default: return nil
        }
    }

    /// 从原始邮件(HEADER+BODY)提取正文文本:优先 text/html,其次 text/plain
    static func extractBody(raw: Data) -> String {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else {
            return String(decoding: raw, as: UTF8.self)
        }
        let headerData = raw.subdata(in: raw.startIndex..<headerEnd.lowerBound)
        let bodyData = raw.subdata(in: headerEnd.upperBound..<raw.endIndex)
        // 展开折叠的头部行(Content-Type 等常折行)
        let headers = String(decoding: headerData, as: UTF8.self)
            .replacingOccurrences(of: "\r\n\t", with: " ")
            .replacingOccurrences(of: "\r\n ", with: " ")
            .replacingOccurrences(of: "\n\t", with: " ")
            .replacingOccurrences(of: "\n ", with: " ")

        let contentType = headerValue("content-type", in: headers)
        let transferEncoding = (headerValue("content-transfer-encoding", in: headers)).lowercased()

        if let boundary = extractBoundary(contentType) {
            for part in splitParts(bodyData, boundary: boundary) {
                let text = extractBody(raw: part)
                if !text.isEmpty { return text }
            }
            return ""
        }
        if contentType.lowercased().contains("text/html") {
            return stripHTML(decodeBody(bodyData, encoding: transferEncoding, contentType: contentType))
        }
        if contentType.lowercased().contains("text/plain") || contentType.isEmpty {
            return decodeBody(bodyData, encoding: transferEncoding, contentType: contentType)
        }
        return ""
    }

    /// 调试用:原始邮件头前几行
    static func debugHeaders(raw: Data) -> String {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else { return "(no header end)" }
        return String(decoding: raw.subdata(in: raw.startIndex..<min(headerEnd.lowerBound, raw.startIndex + 600)), as: UTF8.self)
    }

    private static func decodeBody(_ data: Data, encoding: String, contentType: String) -> String {
        let charset = extractCharset(contentType)
        switch encoding {
        case "base64":
            let cleaned = Data(String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\r\n", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .utf8)
            guard let decoded = Data(base64Encoded: cleaned) else { return "" }
            return decode(decoded, charset: charset)
        case "quoted-printable":
            return decode(decodeQuotedPrintable(data), charset: charset)
        default:
            return decode(data, charset: charset)
        }
    }

    private static func headerValue(_ name: String, in headers: String) -> String {
        for line in headers.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix(name + ":") {
                return String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private static func extractBoundary(_ contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=") else { return nil }
        var value = String(contentType[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            guard let end = value.dropFirst().firstIndex(of: "\"") else { return nil }
            value = String(value[value.index(after: value.startIndex)..<end])
        } else if let semi = value.firstIndex(of: ";") {
            value = String(value[..<semi])
        }
        return value.isEmpty ? nil : value
    }

    private static func extractCharset(_ contentType: String) -> String {
        guard let range = contentType.range(of: "charset=") else { return "utf-8" }
        var value = String(contentType[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            value = String(value.dropFirst())
            if let end = value.firstIndex(of: "\"") { value = String(value[..<end]) }
        } else if let semi = value.firstIndex(of: ";") {
            value = String(value[..<semi])
        }
        return value.isEmpty ? "utf-8" : value
    }

    /// 按 boundary 拆分 multipart 正文
    private static func splitParts(_ body: Data, boundary: String) -> [Data] {
        let marker = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var searchRange = body.startIndex..<body.endIndex
        var positions: [Data.Index] = []
        while let found = body.range(of: marker, options: [], in: searchRange) {
            positions.append(found.lowerBound)
            searchRange = found.upperBound..<body.endIndex
        }
        guard positions.count >= 2 else { return [body] }
        for i in 0..<(positions.count - 1) {
            var start = body.index(after: positions[i])
            if let crlf = body.range(of: Data("\r\n".utf8), options: [], in: start..<positions[i + 1]) {
                start = crlf.upperBound
            }
            parts.append(body.subdata(in: start..<positions[i + 1]))
        }
        return parts
    }

    /// 去掉 HTML 标签与样式块,保留可读文本
    static func stripHTML(_ html: String) -> String {
        var text = html
        for tag in ["style", "script", "head", "title"] {
            if let r = text.range(of: "<\(tag)[^>]*>", options: [.regularExpression, .caseInsensitive]),
               let e = text.range(of: "</\(tag)>", options: [.caseInsensitive], range: r.upperBound..<text.endIndex) {
                text.removeSubrange(r.lowerBound..<e.upperBound)
            }
        }
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</(p|tr|div|table|h[1-6])>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: [.regularExpression])
        let entities: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&yen;": "¥"
        ]
        for (k, v) in entities {
            text = text.replacingOccurrences(of: k, with: v)
        }
        text = text.replacingOccurrences(of: "&#x([0-9a-fA-F]+);", with: " ", options: [.regularExpression])
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .joined(separator: " ")
            .replacingOccurrences(of: " \n", with: "\n")
    }
}

extension String {
    /// 按固定长度切块,便于调试输出
    func chunks(ofLength size: Int) -> [Substring] {
        guard size > 0 else { return [] }
        var chunks: [Substring] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(self[start..<end])
            start = end
        }
        return chunks
    }
}

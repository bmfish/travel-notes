import SwiftUI

// MARK: - 基础形状

struct DashedVLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY + 2))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 2))
        return p
    }
}

struct DashedHLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// 票据撕裂线:竖直虚线 + 上下两个打孔
struct TicketTear: View {
    var lineColor: Color
    var punchColor: Color

    var body: some View {
        ZStack {
            DashedVLine()
                .stroke(lineColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            VStack {
                Circle()
                    .fill(punchColor)
                    .frame(width: 12, height: 12)
                    .offset(y: -6)
                Spacer()
                Circle()
                    .fill(punchColor)
                    .frame(width: 12, height: 12)
                    .offset(y: 6)
            }
        }
    }
}

/// 装饰用的伪二维码(确定性图案)
struct FakeQR: View {
    var size: CGFloat = 40
    var color: Color = Theme.ticketInk

    var body: some View {
        Canvas { context, canvasSize in
            let n = 9
            let cell = canvasSize.width / CGFloat(n)
            for row in 0..<n {
                for col in 0..<n {
                    if (row * 7 + col * 13 + row * col) % 5 < 2 {
                        let rect = CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                                          width: cell, height: cell)
                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }
            for (r, c) in [(0, 0), (0, n - 3), (n - 3, 0)] {
                let rect = CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell,
                                  width: cell * 3, height: cell * 3)
                context.stroke(Path(rect), with: .color(color), lineWidth: 1)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 蓝色磁卡票(2007–2020 风格)

struct BlueTicketFace: View {
    let info: TicketInfo
    var punchColor: Color = Theme.paperBackground

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("中国铁路")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundColor(Theme.railBlue)
                    Text("CHINA RAILWAY")
                        .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                        .tracking(2.5)
                        .foregroundColor(Theme.railBlue.opacity(0.8))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(info.trainNoLine)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundColor(Theme.ticketInk)
                    Text(info.kind ?? "电子客票")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(Theme.ticketGray)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Rectangle()
                .fill(Theme.railBlue.opacity(0.25))
                .frame(height: 0.8)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .center, spacing: 6) {
                        station(info.from)
                        VStack(spacing: 1) {
                            Text(info.trainNoText)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Theme.railBlue)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Theme.railBlue)
                        }
                        station(info.to)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Fmt.cnDate.string(from: info.date))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.ticketInk)
                        if let t = info.departTime {
                            Text(Fmt.clock.string(from: t))
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundColor(Theme.railBlue)
                            Text("开").font(.system(size: 9)).foregroundColor(Theme.ticketGray)
                        }
                    }
                    HStack(spacing: 6) {
                        if let sc = info.seatClass {
                            Text(sc).font(.system(size: 9, weight: .medium)).foregroundColor(Theme.railBlue)
                        }
                        if let kind = info.kind {
                            Text(kind).font(.system(size: 9)).foregroundColor(Theme.ticketGray)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                TicketTear(lineColor: Theme.ticketGray.opacity(0.5), punchColor: punchColor)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 4) {
                    Text(info.seatClass ?? "乘车凭证")
                        .font(.system(size: 8.5))
                        .foregroundColor(Theme.ticketGray)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(info.priceText ?? "—")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(Theme.railBlue)
                    Text(info.seatLine)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.ticketInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    FakeQR(size: 34, color: Theme.ticketInk.opacity(0.75))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black)
                DashedHLine()
                    .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            }
            .frame(height: 12)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.82), lineWidth: 0.8))
    }

    private func station(_ s: String?) -> some View {
        Text(TicketInfo.stationText(s))
            .font(.system(size: 20, weight: .heavy))
            .foregroundColor(Theme.ticketInk)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

// MARK: - 复古红软纸票(90 年代风格)

struct RedTicketFace: View {
    let info: TicketInfo
    var punchColor: Color = Theme.paperBackground

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "star.fill").font(.system(size: 8)).foregroundColor(Theme.railRed)
                Text("中国铁路 CHINA RAILWAY")
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(1)
                    .foregroundColor(Theme.railRed)
                Image(systemName: "star.fill").font(.system(size: 8)).foregroundColor(Theme.railRed)
            }
            .padding(.vertical, 8)

            Rectangle().fill(Theme.railRed.opacity(0.7)).frame(height: 1)

            VStack(spacing: 8) {
                HStack {
                    Text(info.trainNoLine)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(Theme.ticketInk)
                    Spacer()
                    Text(info.kind ?? "乘车凭证")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Theme.railRed)
                }
                HStack(alignment: .center, spacing: 8) {
                    Text(info.stationFrom)
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundColor(Theme.ticketInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.railRed)
                    Text(info.stationTo)
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundColor(Theme.ticketInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                HStack(spacing: 4) {
                    Text(Fmt.cnDate.string(from: info.date))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Theme.ticketInk)
                    if let t = info.departTime {
                        Text(Fmt.clock.string(from: t))
                            .font(.system(size: 12.5, weight: .heavy))
                            .foregroundColor(Theme.railRed)
                        Text("开").font(.system(size: 9)).foregroundColor(Theme.ticketGray)
                    }
                    Spacer()
                    if let p = info.priceText {
                        Text(p).font(.system(size: 14, weight: .heavy)).foregroundColor(Theme.railRed)
                    }
                }
                HStack(spacing: 6) {
                    if let sc = info.seatClass {
                        Text(sc).font(.system(size: 10, weight: .medium)).foregroundColor(Theme.ticketInk)
                    }
                    Text(info.seatLine)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.ticketInk)
                    Spacer()
                    Text(info.serialText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.railRed.opacity(0.8))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Rectangle().fill(Theme.railRed.opacity(0.7)).frame(height: 1)

            Text("限乘当日当次车 · 票价含铁路旅客意外伤害保险")
                .font(.system(size: 7.5))
                .foregroundColor(Theme.railRed.opacity(0.75))
                .padding(.vertical, 5)
        }
        .background(Theme.creamPaper)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Theme.railRed.opacity(0.55), lineWidth: 1)
                .padding(4)
        )
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.railRed.opacity(0.3), lineWidth: 0.8))
    }
}

// MARK: - 票面调度

struct TicketFaceView: View {
    let info: TicketInfo
    var punchColor: Color = Theme.paperBackground

    var body: some View {
        switch info.skin {
        case .red: RedTicketFace(info: info, punchColor: punchColor)
        case .blue: BlueTicketFace(info: info, punchColor: punchColor)
        }
    }
}

// MARK: - 首页微缩票根卡

struct MiniTicketCard: View {
    let info: TicketInfo
    var tilt: Double = 0

    /// 按线路方向配色:回上海=蓝,离上海=绿,其他线路其他色
    private var accent: Color { info.routeColor }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(info.trainNoText)
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(accent))
                    if let kind = info.kind {
                        Text(kind).font(.system(size: 9)).foregroundColor(Theme.ticketGray)
                    }
                    HStack(spacing: 3) {
                        if info.photoCount > 0 {
                            Image(systemName: "photo").font(.system(size: 8))
                            Text("\(info.photoCount)").font(.system(size: 9))
                        }
                        if info.hasNote {
                            Image(systemName: "text.bubble").font(.system(size: 8))
                        }
                    }
                    .foregroundColor(Theme.ticketGray)
                }
                HStack(alignment: .center, spacing: 5) {
                    Text(info.stationFrom)
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundColor(Theme.ticketInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(accent)
                    Text(info.stationTo)
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundColor(Theme.ticketInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Text(dateLine)
                    .font(.system(size: 10.5))
                    .foregroundColor(Theme.ticketGray)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 15)
            .padding(.trailing, 8)
            .padding(.vertical, 12)

            TicketTear(lineColor: Theme.ticketGray.opacity(0.45), punchColor: Theme.paperBackground)
                .frame(width: 14)

            VStack(spacing: 3) {
                Text(info.seatClass ?? "乘车凭证")
                    .font(.system(size: 8))
                    .foregroundColor(Theme.ticketGray)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(info.seatLine)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.ticketInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(info.priceText ?? "—")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(accent)
            }
            .frame(width: 62)
            .padding(.trailing, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white)
                .overlay(alignment: .leading) {
                    Rectangle().fill(accent).frame(width: 4)
                }
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: Color.black.opacity(0.13), radius: 5, x: 0, y: 3)
        .rotationEffect(.degrees(tilt))
    }

    private var dateLine: String {
        var s = Fmt.dotDate.string(from: info.date)
        if let t = info.departTime {
            s += "  " + Fmt.clock.string(from: t) + "开"
        }
        return s
    }
}

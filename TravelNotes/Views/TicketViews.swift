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

// MARK: - 蓝色磁卡票(还原 2007–2020 实票版式)

struct BlueTicketFace: View {
    let info: TicketInfo
    var punchColor: Color = Theme.paperBackground

    private var navy: Color { Color(red: 0.10, green: 0.24, blue: 0.45) }
    private var serialRed: Color { Color(red: 0.80, green: 0.20, blue: 0.16) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 票号 + 局名
            HStack(alignment: .top) {
                Text(info.serialText)
                    .font(.system(size: 15, weight: .heavy, design: .monospaced))
                    .foregroundColor(serialRed)
                Spacer()
                HStack(spacing: 5) {
                    ZStack {
                        Circle().fill(navy)
                        Circle().fill(Color.white).frame(width: 9, height: 9)
                    }
                    .frame(width: 16, height: 16)
                    Text("中国铁路")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(navy)
                }
            }

            // 站名 + 车次线
            HStack(alignment: .center, spacing: 10) {
                Text(info.stationFrom)
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundColor(navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                HStack(spacing: 5) {
                    Rectangle().fill(navy.opacity(0.75)).frame(height: 1.5)
                    Text(info.trainNoLine)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(navy)
                        .fixedSize()
                    Rectangle().fill(navy.opacity(0.75)).frame(height: 1.5)
                }
                Text(info.stationTo)
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundColor(navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            // 日期时刻 + 车厢座位
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(Fmt.cnDate.string(from: info.date))
                        .font(.system(size: 13, weight: .semibold))
                    if let t = info.departTime {
                        Text(Fmt.clock.string(from: t))
                            .font(.system(size: 13, weight: .heavy))
                        Text("开").font(.system(size: 10))
                    }
                }
                .foregroundColor(navy)
                Spacer()
                Text(info.seatLine)
                    .font(.system(size: 15, weight: .heavy, design: .monospaced))
                    .foregroundColor(navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            // 票价 + 席别
            HStack(alignment: .firstTextBaseline) {
                Text(info.priceFullText)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(navy)
                Spacer()
                Text(info.seatClass ?? "新空调硬座")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(navy)
            }

            // 限乘 + 乘车人 + 票号
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("限乘当日当次车")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(navy)
                    if let p = info.passenger, !p.isEmpty {
                        Text(p)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(navy)
                    }
                    Text(info.longSerialText)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(navy.opacity(0.7))
                }
                Spacer()
            }
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Color(red: 0.83, green: 0.90, blue: 0.97),
                                    Color(red: 0.62, green: 0.79, blue: 0.94)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
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

// MARK: - 检票状态徽章(行程卡/详情页共用)

/// 呼吸绿点:正在检票时闪烁
struct PulseDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Theme.routeGreen)
            .frame(width: 6, height: 6)
            .scaleEffect(on ? 1.45 : 0.8)
            .opacity(on ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// 检票状态胶囊:候车 / 正在检票(绿底呼吸点)/ 已发车
struct CheckStatusChip: View {
    let text: String
    /// 行程卡用小号,详情页用常规号
    var small = false

    private var boarding: Bool { text == "正在检票" }
    private var departed: Bool { text == "已发车" }

    var body: some View {
        HStack(spacing: 4) {
            if boarding { PulseDot() }
            Text(text)
                .font(.system(size: small ? 11 : 12,
                              weight: small ? .heavy : .semibold,
                              design: small ? .rounded : .default))
        }
        .foregroundColor(departed ? Theme.ticketGray.opacity(0.8)
                                  : boarding ? Theme.routeGreen : Theme.ticketGray)
        .padding(.horizontal, small ? 8 : 9)
        .padding(.vertical, small ? 4 : 5)
        .background(Capsule().fill(boarding ? Theme.routeGreen.opacity(0.14)
                                            : Theme.ticketGray.opacity(0.10)))
    }
}

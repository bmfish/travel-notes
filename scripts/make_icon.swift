import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let W: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(W), height: Int(W), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func font(_ name: String, _ size: CGFloat) -> CTFont {
    CTFontCreateWithName(name as CFString, size, nil)
}

let fontAttr = NSAttributedString.Key(kCTFontAttributeName as String)
let colorAttr = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

func textWidth(_ text: String, _ f: CTFont) -> CGFloat {
    let line = CTLineCreateWithAttributedString(
        NSMutableAttributedString(string: text, attributes: [fontAttr: f]))
    return CTLineGetTypographicBounds(line, nil, nil, nil)
}

func draw(_ text: String, _ f: CTFont, _ color: CGColor, _ x: CGFloat, _ y: CGFloat) {
    let line = CTLineCreateWithAttributedString(
        NSMutableAttributedString(string: text, attributes: [fontAttr: f, colorAttr: color]))
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

// MARK: 背景:深红渐变 + 斜向高光

let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.78, green: 0.26, blue: 0.20, alpha: 1),
    CGColor(red: 0.52, green: 0.12, blue: 0.09, alpha: 1)
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: W), end: CGPoint(x: W, y: 0), options: [])

ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
ctx.rotate(by: -0.35)
ctx.fill(CGRect(x: -200, y: 500, width: 1600, height: 260))
ctx.rotate(by: 0.7)
ctx.fill(CGRect(x: -200, y: 380, width: 1600, height: 120))
ctx.rotate(by: -0.35)

// MARK: 车票绘制

let inkColor = CGColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1)
let grayColor = CGColor(red: 0.45, green: 0.47, blue: 0.50, alpha: 1)

func ticket(angle: CGFloat, cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat,
            fill: CGColor, accent: CGColor, shadowAlpha: CGFloat,
            trainNo: String?, from: String?, to: String?, price: String?) {
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    ctx.rotate(by: angle)
    let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)

    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 44,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: shadowAlpha))
    ctx.setFillColor(fill)
    let path = CGPath(roundedRect: rect, cornerWidth: 40, cornerHeight: 40, transform: nil)
    ctx.addPath(path)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    ctx.addPath(path)
    ctx.clip()

    // 左侧色条
    ctx.setFillColor(accent)
    ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: 18, height: h))

    let tearX: CGFloat = 230
    if let no = trainNo {
        // 车次芯片
        let chipFont = font("ArialRoundedMTBold", 46)
        let chipW = textWidth(no, chipFont) + 44
        let chip = CGPath(roundedRect: CGRect(x: -w / 2 + 46, y: h / 2 - 116, width: chipW, height: 80),
                          cornerWidth: 18, cornerHeight: 18, transform: nil)
        ctx.setFillColor(accent)
        ctx.addPath(chip)
        ctx.fillPath()
        draw(no, chipFont, CGColor(red: 1, green: 1, blue: 1, alpha: 1),
             -w / 2 + 46 + 22, h / 2 - 96)

        // 站名 + 箭头
        let stationFont = font("PingFangSC-Semibold", 64)
        let arrowFont = font("PingFangSC-Semibold", 52)
        let fromW = textWidth(from ?? "", stationFont)
        let arrowW = textWidth("→", arrowFont)
        let startX = -w / 2 + 46
        draw(from ?? "", stationFont, inkColor, startX, -40)
        let arrowX = startX + fromW + 22
        draw("→", arrowFont, accent, arrowX, -36)
        draw(to ?? "", stationFont, inkColor, arrowX + arrowW + 22, -40)

        // 撕裂虚线
        ctx.setStrokeColor(grayColor)
        ctx.setLineWidth(3)
        ctx.setLineDash(phase: 0, lengths: [16, 14])
        ctx.move(to: CGPoint(x: tearX, y: -h / 2 + 10))
        ctx.addLine(to: CGPoint(x: tearX, y: h / 2 - 10))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // 副券:席别 + 票价
        let smallFont = font("PingFangSC-Medium", 32)
        draw("二等座", smallFont, grayColor, tearX + 34, h / 2 - 84)
        let priceFont = font("ArialRoundedMTBold", 58)
        draw(price ?? "", priceFont, accent, tearX + 34, -58)
    }
    ctx.restoreGState()
}

let cream = CGColor(red: 0.988, green: 0.952, blue: 0.892, alpha: 1)
let creamDim = CGColor(red: 0.925, green: 0.878, blue: 0.80, alpha: 1)
let blueA = CGColor(red: 0.09, green: 0.32, blue: 0.58, alpha: 1)
let greenA = CGColor(red: 0.13, green: 0.60, blue: 0.35, alpha: 1)

// 后面探出的绿色车票
ticket(angle: 0.16, cx: 400, cy: 660, w: 700, h: 300,
       fill: creamDim, accent: greenA, shadowAlpha: 0.30,
       trainNo: nil, from: nil, to: nil, price: nil)

// 前面主车票
ticket(angle: -0.10, cx: 545, cy: 430, w: 820, h: 330,
       fill: cream, accent: blueA, shadowAlpha: 0.38,
       trainNo: "G4098", from: "郑州东", to: "上海虹桥", price: "¥471")

// MARK: 输出

let img = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "/tmp/icon1024.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("icon written to \(out.path)")

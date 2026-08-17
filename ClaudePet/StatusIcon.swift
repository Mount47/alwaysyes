// StatusIcon — 菜单栏状态图标
//
// 图标是一枚黑白圆形徽标(外环 + 上下左右四扇形 + 中心圆), 造型取自 resources/image-1.png。
//
// 两条渲染路径, 由 ~/.claude/pet-config.json 的 iconStyle 选:
//   vector  按构图用 NSBezierPath 重画(默认)。原图是三层同心结构, 但缩到菜单栏的
//           18pt 后, 环间空隙只剩 0.40px、内细环只剩 0.28px —— 亚像素, 必然糊成一坨。
//           所以矢量版砍掉内细环和中间那道 hairline, 只留在这个尺寸下真正看得见的东西,
//           换来任何分辨率都锐利。
//   bitmap  直接用 resources/menubar-icon*.png(已裁掉水印、白转 alpha)。忠于原图,
//           但 @1x 下双环会并成一根粗边。
//
// **全程纯黑白**: 整张图都是模板图(isTemplate), 由系统按菜单栏深浅自动取色, 不带任何
// 自有颜色。状态靠形状区分, 不靠颜色 —— 六个状态的编码见 draw(for:)。
//
// 注意模板图只认 alpha: 不透明像素一律被重绘成前景色。所以"白色"必须画成透明(用
// .clear 合成模式挖空), 不能真的填白, 否则在深色菜单栏上会变成一坨实心。

import Cocoa

enum IconStyle: String {
    case vector, bitmap

    init(configValue: String?) {
        self = IconStyle(rawValue: configValue ?? "") ?? .vector
    }
}

// waiting 是这个 app 的核心状态, 纯黑白下最难做醒目, 所以把强调方式做成可选的
enum WaitingEmphasis: String {
    case solid      // 实心盘挖出十字缝与中心圆: 视觉重量最大, 且保住十字准星的辨识度
    case bold       // 环加粗、中心圆放大
    case plain      // 本体不变, 只靠数字

    init(configValue: String?) {
        self = WaitingEmphasis(rawValue: configValue ?? "") ?? .solid
    }
}

enum StatusIcon {
    // 菜单栏图标的标准尺寸。系统给的高度是 22pt, 留出上下边距后 18pt 是惯例。
    static let size: CGFloat = 18

    // MARK: - 对外入口

    static func image(for state: OverallState, waitingCount: Int,
                      style: IconStyle, emphasis: WaitingEmphasis = .solid) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        draw(for: state, style: style, emphasis: emphasis)
        img.unlockFocus()
        img.isTemplate = true      // 纯黑白: 交给系统按菜单栏深浅取色
        return img
    }

    // MARK: - 六状态编码(纯形状, 无颜色)
    //
    //   idle      常规徽标, 无角标
    //   running   徽标 + 实心角标        在动
    //   review    徽标 + 空心角标        写完了等你看
    //   waiting   徽标强调 + 数字        等你点 yes, 要最醒目
    //   failed    徽标 + 感叹号角标      出错
    //   disabled  常规徽标(半透明交给 NSStatusItem.appearsDisabled, 这里不特殊处理)

    private static func draw(for state: OverallState, style: IconStyle, emphasis: WaitingEmphasis) {
        let badge: BadgeShape?
        switch state {
        case .running: badge = .solid
        case .review:  badge = .hollow
        case .failed:  badge = .bang
        case .waiting, .idle, .disabled: badge = nil
        }

        // 有角标时把徽标缩一点并靠左上, 给右下角腾地方。
        // 不缩的话 18pt 的画布里角标连同它的分离环会从徽标身上咬掉一大块, 轮廓就散了。
        let box: NSRect
        if badge != nil {
            let s = size * 0.80
            box = NSRect(x: 0, y: size - s, width: s, height: s)
        } else {
            box = NSRect(x: 0, y: 0, width: size, height: size)
        }

        let mode: EmblemMode = (state == .waiting) ? emphasis.emblemMode : .normal
        switch style {
        case .vector: drawEmblem(in: box, mode: mode)
        case .bitmap: drawBitmapEmblem(in: box, mode: mode)
        }
        if let b = badge { drawBadge(b) }
    }

    // MARK: - 矢量徽标

    enum EmblemMode { case normal, bold, solid }

    // 各构件相对直径的比例, 量自原图(圆直径 1360px):
    //   外环厚 73/1360 ≈ 0.054 —— 18pt 下不到 1pt, 太细会发虚, 所以放宽到 0.105
    //   中心圆直径 270/1360 ≈ 0.20
    private static func drawEmblem(in box: NSRect, mode: EmblemMode) {
        let d = box.width
        let c = NSPoint(x: box.midX, y: box.midY)
        let r = d / 2 - 0.5                      // 留半点边, 免得边缘被画布切掉

        if mode == .solid {
            drawSolidEmblem(center: c, r: r)
            return
        }

        let bold = (mode == .bold)
        drawEmblemInk(center: c, r: r,
                      ringW: d * (bold ? 0.150 : 0.105),
                      hubR:  d * (bold ? 0.155 : 0.115),
                      spokeGap: d * (bold ? 0.075 : 0.052))
    }

    // 强调态: 整个圆填实, 再挖出十字缝和中心圆外的一圈。
    // 相比"取负片"(实心盘挖掉徽标墨迹), 这个方向才对 —— 那个徽标本身墨迹占比就高,
    // 负片几乎是空的, 反而比常态更不显眼。这里是加墨而不是减墨, 菜单栏上就是一颗重实的圆点。
    private static func drawSolidEmblem(center c: NSPoint, r: CGFloat) {
        let d = r * 2
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: d, height: d)).fill()

        let ctx = NSGraphicsContext.current
        ctx?.compositingOperation = .clear
        NSColor.black.setFill()

        // 十字缝: 把实心盘切成四块, 保住十字准星的辨识度
        let gap = d * 0.095
        NSBezierPath(rect: NSRect(x: c.x - gap / 2, y: c.y - r - 1, width: gap, height: d + 2)).fill()
        NSBezierPath(rect: NSRect(x: c.x - r - 1, y: c.y - gap / 2, width: d + 2, height: gap)).fill()

        // 中心圆外挖一圈, 让中心点从四块里独立出来
        let hubR = d * 0.115
        let sep = d * 0.075
        NSBezierPath(ovalIn: NSRect(x: c.x - hubR - sep, y: c.y - hubR - sep,
                                    width: (hubR + sep) * 2, height: (hubR + sep) * 2)).fill()
        ctx?.compositingOperation = .sourceOver

        fillHub(c, hubR)
    }

    // 画徽标的墨迹部分(环 + 四扇形 + 中心圆)
    private static func drawEmblemInk(center c: NSPoint, r: CGFloat,
                                      ringW: CGFloat, hubR: CGFloat, spokeGap: CGFloat) {
        NSColor.black.setFill()

        // 外环
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ring.append(NSBezierPath(ovalIn: NSRect(x: c.x - r + ringW, y: c.y - r + ringW,
                                                width: (r - ringW) * 2, height: (r - ringW) * 2)))
        ring.windingRule = .evenOdd
        ring.fill()

        // 四扇形: 先画整条环带, 再用十字缝切成四块
        let spokeOuter = r - ringW - r * 0.155
        let spokeInner = hubR + r * 0.145
        guard spokeOuter > spokeInner else { fillHub(c, hubR); return }

        let band = NSBezierPath(ovalIn: NSRect(x: c.x - spokeOuter, y: c.y - spokeOuter,
                                               width: spokeOuter * 2, height: spokeOuter * 2))
        band.append(NSBezierPath(ovalIn: NSRect(x: c.x - spokeInner, y: c.y - spokeInner,
                                                width: spokeInner * 2, height: spokeInner * 2)))
        band.windingRule = .evenOdd
        band.fill()

        // 十字缝要挖成真透明 —— 模板图只认 alpha, 填白没用, 在深色菜单栏上会变成一坨实心
        let ctx = NSGraphicsContext.current
        ctx?.compositingOperation = .clear
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: c.x - spokeGap / 2, y: c.y - spokeOuter - 1,
                                  width: spokeGap, height: spokeOuter * 2 + 2)).fill()
        NSBezierPath(rect: NSRect(x: c.x - spokeOuter - 1, y: c.y - spokeGap / 2,
                                  width: spokeOuter * 2 + 2, height: spokeGap)).fill()
        ctx?.compositingOperation = .sourceOver

        fillHub(c, hubR)
    }

    private static func fillHub(_ c: NSPoint, _ hubR: CGFloat) {
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - hubR, y: c.y - hubR,
                                    width: hubR * 2, height: hubR * 2)).fill()
    }

    // MARK: - 位图徽标

    private static var cachedBitmap: NSImage??      // 双层可选: 外层"查过没", 内层"有没有"

    private static func bitmapEmblem() -> NSImage? {
        if let c = cachedBitmap { return c }
        // 三档 @1x/@2x/@3x 同名放在 Resources 里, NSImage 会按屏幕自动挑
        let img = Bundle.main.image(forResource: "menubar-icon")
        cachedBitmap = .some(img)
        return img
    }

    private static func drawBitmapEmblem(in box: NSRect, mode: EmblemMode) {
        // 强调态没有对应的位图素材(原图就一张常态), 直接交给矢量画。
        // 试过用位图自己的 alpha 去挖实心盘, 但位图的 alpha 就是墨迹本身, 挖出来是
        // 那个稀疏的负片, 反而比常态还不显眼 —— 和矢量版放弃"反白"是同一个原因。
        guard mode == .normal, let img = bitmapEmblem() else {
            drawEmblem(in: box, mode: mode)      // 也覆盖资源缺失(没跑 build.sh)的回退
            return
        }
        img.draw(in: box)
    }

    // MARK: - 角标

    private enum BadgeShape { case solid, hollow, bang }

    // 角标放右下角, 先用 .clear 挖掉一圈透明再画。
    // 现在那个点丑的根因就是没有这一圈: 实心点零间隙贴着本体, 糊在一起像瑕疵而不像徽标。
    private static func drawBadge(_ shape: BadgeShape) {
        let d = size * 0.40                     // 角标直径
        let knock = size * 0.075                // 分离环宽度
        let cx = size - d / 2 - 0.5
        let cy = d / 2 + 0.5
        let box = NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)

        NSGraphicsContext.current?.compositingOperation = .clear
        NSColor.black.setFill()
        NSBezierPath(ovalIn: box.insetBy(dx: -knock, dy: -knock)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        NSColor.black.setFill()
        switch shape {
        case .solid:
            NSBezierPath(ovalIn: box).fill()
        case .hollow:
            let w = d * 0.30
            let p = NSBezierPath(ovalIn: box)
            p.append(NSBezierPath(ovalIn: box.insetBy(dx: w, dy: w)))
            p.windingRule = .evenOdd
            p.fill()
        case .bang:
            // 实心圆底 + 挖出来的竖杠和点, 比在 7pt 里画个 "!" 字形清楚得多
            NSBezierPath(ovalIn: box).fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSColor.black.setFill()
            let bw = d * 0.17
            NSBezierPath(rect: NSRect(x: cx - bw / 2, y: cy - d * 0.04,
                                      width: bw, height: d * 0.28)).fill()
            NSBezierPath(ovalIn: NSRect(x: cx - bw / 2, y: cy - d * 0.22,
                                        width: bw, height: bw)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }
    }
}

private extension WaitingEmphasis {
    var emblemMode: StatusIcon.EmblemMode {
        switch self {
        case .solid: return .solid
        case .bold:  return .bold
        case .plain: return .normal
        }
    }
}


// MARK: - 设计对照表(仅供 `ClaudePet --dump-icons` 用)
//
// 六状态 × 两种样式 × 深浅菜单栏, 一次渲成一张图。改了图标几何就跑一遍看看,
// 比在真机菜单栏上一个个状态凑出来快得多。
enum IconSheet {
    private static let states: [(String, OverallState)] = [
        ("idle", .idle), ("running", .running), ("review", .review),
        ("waiting", .waiting), ("failed", .failed), ("disabled", .disabled),
    ]

    // 模板图在菜单栏里会被系统按前景色重绘, 这里手动上色模拟同样的效果
    private static func tinted(_ img: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: img.size)
        out.lockFocus()
        img.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceIn)
        out.unlockFocus()
        return out
    }

    static func write(to path: String) {
        let zoom: CGFloat = 5, pad: CGFloat = 14, label: CGFloat = 96
        let cellW = StatusIcon.size * zoom + pad * 2
        let rowH = StatusIcon.size * zoom + 30
        let styles: [(String, IconStyle)] = [("矢量", .vector), ("位图", .bitmap)]
        let bands: [(NSColor, NSColor, String)] = [
            (NSColor(calibratedWhite: 0.95, alpha: 1), .black, "浅"),
            (NSColor(calibratedWhite: 0.17, alpha: 1), .white, "深"),
        ]
        let W = cellW * CGFloat(states.count) + label
        let H = rowH * CGFloat(styles.count * bands.count)

        let sheet = NSImage(size: NSSize(width: W, height: H))
        sheet.lockFocus()
        var row = 0
        for (sname, style) in styles {
            for (bg, fg, bname) in bands {
                let y0 = H - rowH * CGFloat(row + 1)
                bg.setFill()
                NSRect(x: 0, y: y0, width: W, height: rowH).fill()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: fg,
                ]
                ("\(sname) · \(bname)" as NSString).draw(
                    at: NSPoint(x: 8, y: y0 + rowH / 2 - 8), withAttributes: attrs)
                for (i, (name, st)) in states.enumerated() {
                    let raw = StatusIcon.image(for: st, waitingCount: 3, style: style)
                    let img = tinted(raw, st == .disabled ? fg.withAlphaComponent(0.4) : fg)
                    let x = label + cellW * CGFloat(i) + pad
                    img.draw(in: NSRect(x: x, y: y0 + 22,
                                        width: StatusIcon.size * zoom, height: StatusIcon.size * zoom))
                    // 右上角再按真实 18pt 画一遍 —— 放大图好看不代表小尺寸能认
                    img.draw(in: NSRect(x: x + StatusIcon.size * (zoom - 1), y: y0 + rowH - 21,
                                        width: StatusIcon.size, height: StatusIcon.size))
                    if row == 0 {
                        (name as NSString).draw(at: NSPoint(x: x, y: y0 + 5), withAttributes: attrs)
                    }
                }
                row += 1
            }
        }
        sheet.unlockFocus()

        guard let tiff = sheet.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { print("渲染失败"); return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("→ \(path)")
    }
}

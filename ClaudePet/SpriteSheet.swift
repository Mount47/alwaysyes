// SpriteSheet — 加载并播放 petdex / Codex 格式的精灵图
//
// 列数恒为 8, 单帧恒为 192×208, 行数按"帧宽高比 192:208"从实际像素反推(兼容等比缩放过的图):
//   9 行 = 1536×1872   Codex / petdex 官方规范
//   11 行 = 1536×2288  多出的 2 行是 16 个朝向(眼球跟随用), 本 app 暂不用
//
// 行语义有两代, 且**互不兼容**, 必须区分:
//
//   codex9 —— Codex 官方动作库, 每行帧数不等:
//     0 idle(6)  1 running-right(8)  2 running-left(8)  3 waving(4)  4 jumping(5)
//     5 failed(8)  6 waiting(6)  7 running(6)  8 review(6)
//
//   legacy6 —— 本仓库 make-pet.py 自产的图, 每行恒 6 帧, 行 6~8 复用 idle:
//     0 idle  1 wave  2 run  3 failed  4 review  5 jump
//
// 判定不靠文件名也不靠 pet.json(codex-anime-pets 的 pet.json 没有 source 字段),
// 而是加载时把整图缩绘到一张小位图, 数出每行的非空帧数当指纹:
// legacy6 是清一色 6, codex9 的 row1 有 8 帧、row3 只有 4 帧。
//
// 每行的循环帧数也直接用实测值, 不写死 6 —— 否则 4 帧的挥手行会播出 2 帧空白, 宠物闪一下消失。
//
// 用法: 加载 spritesheet.webp → setState(.waiting 等) → 每帧 Timer 调 currentFrame()

import Cocoa

// 动画状态。命名照 Codex 动作库, legacy6 的图会自动回退到它有的那几行。
enum PetAnim {
    case idle           // 待机: 发呆/眨眼/轻微呼吸
    case runningRight   // 向右跑
    case runningLeft    // 向左跑
    case waving         // 挥手打招呼
    case jumping        // 跳跃: 开心/引起注意
    case failed         // 出错
    case waiting        // 等你输入或确认
    case running        // 工作中
    case review         // 检查中: 代码写完等你看 diff
}

// 精灵图的行语义代际
enum SpriteLayout {
    case codex9     // Codex / petdex 官方
    case legacy6    // make-pet.py 自产
}

class SpriteSheet {
    static let cols = 8
    static let frameW = 192
    static let frameH = 208

    // 不透明掩膜的分辨率(与帧同比例)。点击穿透只需大致轮廓, 48×52 足够, 内存也可忽略。
    static let maskW = 48
    static let maskH = 52

    // 数每行非空帧数时用的缩略图格子大小 —— 只是判断"这格有没有画东西", 不需要高分辨率
    private static let probeW = 24
    private static let probeH = 26

    private let sheet: NSImage
    let rows: Int                 // 实际行数: 9 或 11
    let layout: SpriteLayout
    private let cellW: Int
    private let cellH: Int
    private let frameCounts: [Int]   // 每行的非空帧数(至少 1)
    private(set) var loaded = false

    private var state: PetAnim = .idle
    private var frameIndex = 0

    // 掩膜缓存: key = 行号*100+帧号(帧数最多 8, 不会撞), 值 = maskW×maskH 的布尔网格
    // (行优先, 与 NSBitmapImageRep 同为左上原点)
    private var maskCache: [Int: [Bool]] = [:]

    // 加载失败返回 nil, 调用方回退到 emoji
    init?(path: String) {
        guard let img = NSImage(contentsOfFile: path),
              let rep = img.representations.first else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w >= Self.cols, h >= Self.cols else { return nil }

        // 反推行数: 帧宽 = 图宽/8, 期望帧高 = 帧宽 × 208/192, 行数 = 图高 / 期望帧高
        let cw = w / Self.cols
        let expectedCellH = Double(cw) * Double(Self.frameH) / Double(Self.frameW)
        var r = Int((Double(h) / expectedCellH).rounded())
        if r < 6 { r = 9 }   // 非标准图反推不出来 → 按 9 行处理(至少要够放下 6 个状态)

        // 点数与像素对齐, 这样后面 draw(from:) 的源矩形可以直接用像素坐标
        img.size = NSSize(width: w, height: h)

        self.sheet = img
        self.rows = r
        self.cellW = w / Self.cols
        self.cellH = h / r

        let counts = Self.probeFrameCounts(img, rows: r)
        self.frameCounts = counts
        self.layout = Self.detectLayout(counts)
        self.loaded = true
    }

    // MARK: - 布局识别

    // 把整图缩绘到一张 (8*probeW) × (rows*probeH) 的小位图, 逐格看有没有不透明像素。
    // 只画一次, 开销可以忽略。失败时退回"每行都是 8 帧"(等价于旧的写死行为, 不会更差)。
    private static func probeFrameCounts(_ img: NSImage, rows: Int) -> [Int] {
        let w = cols * probeW, h = rows * probeH
        let fallback = [Int](repeating: cols, count: rows)
        guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return fallback }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h),
                 from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        var counts: [Int] = []
        for row in 0..<rows {
            var n = 0
            for col in 0..<cols where cellHasInk(rep, col: col, row: row) { n += 1 }
            counts.append(max(1, n))   // 整行空白也当 1 帧, 免得取模除零
        }
        return counts
    }

    // 该格里有没有画东西。注意 NSBitmapImageRep 的 y 自上而下, 与精灵图行号同向。
    private static func cellHasInk(_ rep: NSBitmapImageRep, col: Int, row: Int) -> Bool {
        let x0 = col * probeW, y0 = row * probeH
        for y in stride(from: y0, to: y0 + probeH, by: 2) {
            for x in stride(from: x0, to: x0 + probeW, by: 2) {
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.1 { return true }
            }
        }
        return false
    }

    // 指纹判定: legacy6 每行恒 6 帧; codex9 的 row1 是 8 帧跑动、row3 只有 4 帧挥手。
    // 任一条命中就当 codex9 —— 官方图是主流, 判错的代价也只是行号错位而非崩溃。
    private static func detectLayout(_ counts: [Int]) -> SpriteLayout {
        guard counts.count >= 6 else { return .legacy6 }
        if counts[1] > 6 || counts[3] < 6 { return .codex9 }
        return .legacy6
    }

    // MARK: - 状态 → 行号 / 帧数 / 速度

    // 当前布局下, 某个状态画在第几行。legacy6 缺的状态回退到它最接近的那一行。
    private func row(for s: PetAnim) -> Int {
        let r: Int
        switch layout {
        case .codex9:
            switch s {
            case .idle:         r = 0
            case .runningRight: r = 1
            case .runningLeft:  r = 2
            case .waving:       r = 3
            case .jumping:      r = 4
            case .failed:       r = 5
            case .waiting:      r = 6
            case .running:      r = 7
            case .review:       r = 8
            }
        case .legacy6:
            // 0 idle / 1 wave / 2 run / 3 failed / 4 review / 5 jump
            switch s {
            case .idle:                                 r = 0
            case .waving:                               r = 1
            case .running, .runningRight, .runningLeft: r = 2
            case .failed:                               r = 3
            case .review, .waiting:                     r = 4   // 没有独立的 waiting 行
            case .jumping:                              r = 5
            }
        }
        return min(r, rows - 1)
    }

    // 当前状态这一行有几帧(实测值)
    private func frameCount(for s: PetAnim) -> Int {
        let r = row(for: s)
        return r < frameCounts.count ? frameCounts[r] : Self.cols
    }

    // 每状态的单帧时长。跑动帧多, 用统一时长会拖成慢动作; 跳跃要脆一点。
    static func interval(for s: PetAnim) -> TimeInterval {
        switch s {
        case .running, .runningRight, .runningLeft: return 0.10
        case .jumping:                              return 0.11
        case .waving:                               return 0.15
        case .idle, .waiting, .review, .failed:     return 1.1 / 6.0   // ≈183ms
        }
    }

    // 当前状态的单帧时长, 供 PetController 决定定时器间隔
    var currentInterval: TimeInterval { Self.interval(for: state) }

    // MARK: - 播放

    func setState(_ s: PetAnim) {
        if state != s { state = s; frameIndex = 0 }
    }

    // 推进到下一帧(由外部 Timer 每 currentInterval 调一次)。
    // 按该行的真实帧数取模 —— 写死 6 会让 4 帧的挥手行播出空白。
    func advance() {
        frameIndex = (frameIndex + 1) % frameCount(for: state)
    }

    // 当前帧图像。按实际像素尺寸等比切分, 兼容非标准尺寸的图。
    func currentFrame() -> NSImage {
        let r = row(for: state)
        let col = min(frameIndex, Self.cols - 1)
        // 源矩形(注意 NSImage 坐标系原点在左下, 精灵图第0行在顶部)
        let srcX = col * cellW
        let srcY = (rows - 1 - r) * cellH   // 翻转行号到左下坐标系
        let srcRect = NSRect(x: srcX, y: srcY, width: cellW, height: cellH)

        let out = NSImage(size: NSSize(width: cellW, height: cellH))
        out.lockFocus()
        sheet.draw(at: .zero, from: srcRect, operation: .copy, fraction: 1.0)
        out.unlockFocus()
        return out
    }

    // 当前帧的不透明掩膜, 供点击穿透判定。懒生成 + 缓存(最多 9 行 × 8 帧 = 72 份)。
    // 直接从 currentFrame() 渲染出来, 不重新推导行翻转 —— 掩膜永远和屏幕上画的那一帧一致。
    func currentMask() -> [Bool] {
        let key = row(for: state) * 100 + frameIndex
        if let m = maskCache[key] { return m }
        let m = Self.buildMask(from: currentFrame())
        maskCache[key] = m
        return m
    }

    // 把一帧缩画到 maskW×maskH 的位图上, 逐点取 alpha
    private static func buildMask(from img: NSImage) -> [Bool] {
        let w = maskW, h = maskH
        let fallback = [Bool](repeating: true, count: w * h)   // 兜底: 当作整块不透明(退回旧行为)
        guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return fallback }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h),
                 from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        var m = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.1 {
                    m[y * w + x] = true
                }
            }
        }
        return m
    }
}

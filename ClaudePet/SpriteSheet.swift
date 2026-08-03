// SpriteSheet — 加载并播放 petdex / Codex 格式的精灵图
//
// 两代规范, 列数恒为 8, 单帧恒为 192×208:
//   v1  8 列 × 9  行 = 1536×1872
//   v2  8 列 × 11 行 = 1536×2288   多出的 2 行是 16 个朝向(眼球跟随用), 本 app 暂不用
// 从 ChatGPT / Codex 导出的宠物默认就是 v2, 所以行数不能写死 9 —— 按 "帧宽高比 192:208"
// 从图片实际像素反推, 同时兼容等比缩放过的图。
//
// 行 = 动画状态, 前 6 行顺序: idle, wave, run, failed, review, jump
// 每状态 6 帧(占该行前 6 列), 循环时长 1100ms → 每帧 ~183ms
//
// 用法: 加载 spritesheet.webp → setState(.idle 等) → 每帧 Timer 调 currentFrame()

import Cocoa

enum PetAnim: Int {
    case idle = 0, wave = 1, run = 2, failed = 3, review = 4, jump = 5
}

class SpriteSheet {
    static let cols = 8
    static let framesPerState = 6
    static let frameW = 192
    static let frameH = 208
    static let frameInterval: TimeInterval = 1.1 / 6.0   // 1100ms / 6 帧

    // 不透明掩膜的分辨率(与帧同比例)。点击穿透只需大致轮廓, 48×52 足够, 内存也可忽略。
    static let maskW = 48
    static let maskH = 52

    private let sheet: NSImage
    private let pxW: Int          // 整图像素宽
    private let pxH: Int
    let rows: Int                 // 实际行数: 9=v1, 11=v2
    private let cellW: Int
    private let cellH: Int
    private(set) var loaded = false

    private var state: PetAnim = .idle
    private var frameIndex = 0

    // 掩膜缓存: key = 状态*100+帧号, 值 = maskW×maskH 的布尔网格(行优先, 与 NSBitmapImageRep 同为左上原点)
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
        if r < 6 { r = 9 }   // 非标准图反推不出来 → 按 v1 处理(至少要够 6 行放下 6 个状态)

        // 点数与像素对齐, 这样后面 draw(from:) 的源矩形可以直接用像素坐标
        img.size = NSSize(width: w, height: h)

        self.sheet = img
        self.pxW = w
        self.pxH = h
        self.rows = r
        self.cellW = w / Self.cols
        self.cellH = h / r
        self.loaded = true
    }

    func setState(_ s: PetAnim) {
        if state != s { state = s; frameIndex = 0 }
    }

    // 推进到下一帧(由外部 Timer 每 frameInterval 调一次)
    func advance() {
        frameIndex = (frameIndex + 1) % Self.framesPerState
    }

    // 当前帧图像。按实际像素尺寸等比切分, 兼容非标准尺寸的图。
    func currentFrame() -> NSImage {
        let col = frameIndex
        let row = state.rawValue
        // 源矩形(注意 NSImage 坐标系原点在左下, 精灵图第0行在顶部)
        let srcX = col * cellW
        let srcY = (rows - 1 - row) * cellH   // 翻转行号到左下坐标系
        let srcRect = NSRect(x: srcX, y: srcY, width: cellW, height: cellH)

        let out = NSImage(size: NSSize(width: cellW, height: cellH))
        out.lockFocus()
        sheet.draw(at: .zero, from: srcRect, operation: .copy, fraction: 1.0)
        out.unlockFocus()
        return out
    }

    // 当前帧的不透明掩膜, 供点击穿透判定。懒生成 + 缓存(最多 6 态 × 6 帧 = 36 份)。
    // 直接从 currentFrame() 渲染出来, 不重新推导行翻转 —— 掩膜永远和屏幕上画的那一帧一致。
    func currentMask() -> [Bool] {
        let key = state.rawValue * 100 + frameIndex
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

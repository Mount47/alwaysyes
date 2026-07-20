// SpriteSheet — 加载并播放 petdex 格式的精灵图
//
// petdex 精灵图规范(固定约定, 不在 pet.json 里):
//   8 列 × 9 行网格, 每帧 192×208 px
//   行 = 动画状态, 顺序: idle, wave, run, failed, review, jump, extra1, extra2
//   每状态 6 帧(占该行前 6 列), 循环时长 1100ms → 每帧 ~183ms
//
// 用法: 加载 spritesheet.webp → setState(.idle 等) → 每帧 Timer 调 currentFrame()

import Cocoa

enum PetAnim: Int {
    case idle = 0, wave = 1, run = 2, failed = 3, review = 4, jump = 5
}

class SpriteSheet {
    static let cols = 8
    static let rows = 9
    static let framesPerState = 6
    static let frameW = 192
    static let frameH = 208
    static let frameInterval: TimeInterval = 1.1 / 6.0   // 1100ms / 6 帧

    private let sheet: NSImage
    private let pxW: Int          // 整图像素宽
    private let pxH: Int
    private(set) var loaded = false

    private var state: PetAnim = .idle
    private var frameIndex = 0

    // 加载失败返回 nil, 调用方回退到 emoji
    init?(path: String) {
        guard let img = NSImage(contentsOfFile: path),
              let rep = img.representations.first else { return nil }
        self.sheet = img
        self.pxW = rep.pixelsWide
        self.pxH = rep.pixelsHigh
        // 宽松校验: 至少能按 8×9 切出正整数帧
        guard pxW >= Self.cols, pxH >= Self.rows else { return nil }
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
        let cellW = pxW / Self.cols
        let cellH = pxH / Self.rows
        let col = frameIndex
        let row = state.rawValue
        // 源矩形(注意 NSImage 坐标系原点在左下, 精灵图第0行在顶部)
        let srcX = col * cellW
        let srcY = (Self.rows - 1 - row) * cellH   // 翻转行号到左下坐标系
        let srcRect = NSRect(x: srcX, y: srcY, width: cellW, height: cellH)

        let out = NSImage(size: NSSize(width: cellW, height: cellH))
        out.lockFocus()
        sheet.draw(at: .zero, from: srcRect, operation: .copy, fraction: 1.0)
        out.unlockFocus()
        return out
    }
}

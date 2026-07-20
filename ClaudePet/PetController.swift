// PetController — 桌面浮动宠物窗口
// 透明、无边框、浮在所有窗口最上层、可鼠标拖到屏幕任意位置(含多显示器)。
// 显示一个大 emoji 作为宠物形象(占位, 后续换像素美术/动画帧),
// 有项目在 waiting 时头顶冒气泡显示是哪个项目。位置持久化。

import Cocoa

// 宠物窗口的自定义视图: 画精灵帧(有则优先) 或 emoji 占位, 加可选气泡
class PetView: NSView {
    var emoji: String = "🐣"
    var frame_: NSImage? = nil  // 当前精灵帧; 非 nil 时替代 emoji
    var bubble: String? = nil   // 非 nil 时在宠物上方画气泡
    var contextMenu: NSMenu?    // 右键菜单(由 AppDelegate 注入)

    // 右键(或 Control+左键)时弹出上下文菜单
    override func menu(for event: NSEvent) -> NSMenu? {
        return contextMenu
    }

    override func draw(_ dirtyRect: NSRect) {
        // 宠物本体: 精灵帧优先, 否则 emoji
        if let frame = frame_ {
            let maxW = bounds.width
            let maxH = bounds.height - 22   // 顶部留给气泡
            let sz = frame.size
            let scale = min(maxW / sz.width, maxH / sz.height, 1.0)
            let w = sz.width * scale, h = sz.height * scale
            let x = (bounds.width - w) / 2
            frame.draw(in: NSRect(x: x, y: 2, width: w, height: h))
        } else {
            let petFont = NSFont.systemFont(ofSize: 44)
            let petAttrs: [NSAttributedString.Key: Any] = [.font: petFont]
            let petStr = emoji as NSString
            let petSize = petStr.size(withAttributes: petAttrs)
            let petX = (bounds.width - petSize.width) / 2
            petStr.draw(at: NSPoint(x: petX, y: 4), withAttributes: petAttrs)
        }

        // 气泡(项目名), 只在 waiting 时有
        guard let text = bubble else { return }
        let font = NSFont.boldSystemFont(ofSize: 11)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let str = text as NSString
        let tsize = str.size(withAttributes: attrs)
        let padX: CGFloat = 8, padY: CGFloat = 4
        let bw = tsize.width + padX * 2
        let bh = tsize.height + padY * 2
        let bx = (bounds.width - bw) / 2
        let by = bounds.height - bh - 2

        let bubbleRect = NSRect(x: bx, y: by, width: bw, height: bh)
        let path = NSBezierPath(roundedRect: bubbleRect, xRadius: 6, yRadius: 6)
        NSColor(calibratedRed: 0.85, green: 0.2, blue: 0.2, alpha: 0.92).setFill()
        path.fill()
        str.draw(at: NSPoint(x: bx + padX, y: by + padY), withAttributes: attrs)
    }
}

class PetController {
    private var window: NSWindow?
    private let view = PetView()
    private let size = NSSize(width: 150, height: 172)  // 容纳 192×208 精灵缩放 + 顶部气泡
    private let posPath = home.appendingPathComponent(".claude/pet-pos.json")
    private var sprite: SpriteSheet?
    private var animTimer: Timer?
    private var currentSpritePath: String?

    // 显示宠物窗口(幂等)
    func show() {
        if window != nil { return }
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating                       // 浮在普通窗口之上
        w.isMovableByWindowBackground = true      // 拖背景即可移动窗口
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary] // 所有桌面/全屏都跟随
        w.ignoresMouseEvents = false
        view.frame = NSRect(origin: .zero, size: size)
        w.contentView = view
        w.setFrameOrigin(loadPosition())
        w.orderFrontRegardless()
        window = w

        // 拖动结束后记住位置
        NotificationCenter.default.addObserver(
            self, selector: #selector(savePosition),
            name: NSWindow.didMoveNotification, object: w)
    }

    func hide() {
        if let w = window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: w)
            w.orderOut(nil)
        }
        window = nil
        animTimer?.invalidate()
        animTimer = nil
    }

    var isVisible: Bool { window != nil }

    // 注入右键菜单(由 AppDelegate 提供,含"隐藏宠物"等动作)
    func setContextMenu(_ menu: NSMenu) {
        view.contextMenu = menu
    }

    // 加载精灵图(路径变化时才重载)。传 nil 或加载失败 → 回退 emoji 模式
    func loadSprite(path: String?) {
        if path == currentSpritePath { return }
        currentSpritePath = path
        if let p = path, let s = SpriteSheet(path: p) {
            sprite = s
            startAnimating()
        } else {
            sprite = nil
            animTimer?.invalidate(); animTimer = nil
            view.frame_ = nil
        }
    }

    private func startAnimating() {
        animTimer?.invalidate()
        animTimer = Timer.scheduledTimer(withTimeInterval: SpriteSheet.frameInterval, repeats: true) { [weak self] _ in
            guard let self = self, let sp = self.sprite, self.window != nil else { return }
            sp.advance()
            self.view.frame_ = sp.currentFrame()
            self.view.needsDisplay = true
        }
    }

    // 更新: emoji 回退文案 + 动画状态 + 气泡
    func update(emoji: String, anim: PetAnim, bubble: String?) {
        view.emoji = emoji
        view.bubble = bubble
        if let sp = sprite {
            sp.setState(anim)
            view.frame_ = sp.currentFrame()
        } else {
            view.frame_ = nil
        }
        view.needsDisplay = true
    }

    // MARK: - 位置持久化
    @objc private func savePosition() {
        guard let origin = window?.frame.origin else { return }
        let obj: [String: Any] = ["x": origin.x, "y": origin.y]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: posPath)
        }
    }

    private func loadPosition() -> NSPoint {
        if let data = try? Data(contentsOf: posPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let x = obj["x"] as? Double, let y = obj["y"] as? Double {
            return NSPoint(x: x, y: y)
        }
        // 默认: 主屏右下角
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            return NSPoint(x: vf.maxX - size.width - 40, y: vf.minY + 40)
        }
        return NSPoint(x: 200, y: 200)
    }
}

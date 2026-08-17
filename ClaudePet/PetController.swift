// PetController — 桌面浮动宠物窗口
// 透明、无边框、浮在所有窗口最上层、可鼠标拖到屏幕任意位置(含多显示器)。
// 显示精灵帧(有则优先)或大 emoji 作为宠物形象,
// 有项目在 waiting 时头顶冒气泡显示是哪个项目, 点气泡里的项目名可跳到对应终端。位置持久化。
//
// 鼠标只被"画到实际像素的地方"拦截: 宠物周围的透明区域点击穿透到底下的窗口。

import Cocoa

// 宠物窗口的自定义视图: 画精灵帧(有则优先) 或 emoji 占位, 加可选气泡
class PetView: NSView {
    var emoji: String = "🐣"
    var frame_: NSImage? = nil  // 当前精灵帧; 非 nil 时替代 emoji
    var mask: [Bool]? = nil     // 当前帧的不透明掩膜(SpriteSheet.maskW×maskH), 用于点击穿透
    var waitingProjects: [String] = []  // 正在等确认的项目名(可多个)
    var bubbleVisible: Bool = false     // 气泡是否显示: 仅在悬停/点击时为 true
    var hoveredLine: Int = -1           // 鼠标压在气泡第几行(-1 = 没压在任何一行)
    var contextMenu: NSMenu?    // 右键菜单(由 AppDelegate 注入)
    var onDesiredSizeChange: ((NSSize) -> Void)?     // 请求窗口按气泡尺寸伸缩
    var onProjectClick: ((Int) -> Void)?             // 点了气泡里第 i 行项目

    static let petAreaH: CGFloat = 150  // 底部固定留给宠物, 气泡在其上方, 二者不重叠
    static let baseWidth: CGFloat = 150 // 没有气泡时的窗口宽度; 气泡更宽时窗口临时撑开
    private var trackingArea: NSTrackingArea?
    private var hoverTimer: Timer?      // 点击穿透后 mouseExited 可能收不到, 用轮询兜底收气泡

    // 右键(或 Control+左键)时弹出上下文菜单
    override func menu(for event: NSEvent) -> NSMenu? {
        return contextMenu
    }

    // MARK: - 命中测试: 只有不透明的宠物本体和气泡拦鼠标, 其余区域穿透

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return isInteractive(at: p) ? self : nil
    }

    // p 为本视图坐标(左下原点)
    func isInteractive(at p: NSPoint) -> Bool {
        if bubbleVisible, !waitingProjects.isEmpty, bubbleHitRect().contains(p) { return true }
        let r = petDrawRect()
        guard r.contains(p), r.width > 0, r.height > 0 else { return false }
        guard let mask = mask, mask.count == SpriteSheet.maskW * SpriteSheet.maskH else {
            return true   // emoji 模式 / 没掩膜 → 整块宠物区可点(退回旧行为)
        }
        let nx = (p.x - r.minX) / r.width           // 0..1 左→右
        let ny = (p.y - r.minY) / r.height          // 0..1 下→上
        let mx = min(SpriteSheet.maskW - 1, max(0, Int(nx * CGFloat(SpriteSheet.maskW))))
        let my = min(SpriteSheet.maskH - 1, max(0, Int((1 - ny) * CGFloat(SpriteSheet.maskH))))  // 掩膜行号自上而下
        return mask[my * SpriteSheet.maskW + mx]
    }

    // MARK: - 悬停显隐气泡

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        // 只跟踪底部宠物区域, 避免气泡展开后的空白区误触发
        let petRect = NSRect(x: 0, y: 0, width: bounds.width, height: PetView.petAreaH)
        let ta = NSTrackingArea(rect: petRect,
                                options: [.mouseEnteredAndExited, .activeAlways],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    private func setBubble(_ visible: Bool) {
        let want = visible && !waitingProjects.isEmpty
        guard want != bubbleVisible else { return }
        bubbleVisible = want
        if want { startHoverWatch() } else { stopHoverWatch(); hoveredLine = -1 }
        onDesiredSizeChange?(desiredSize())
        needsDisplay = true
    }

    // 气泡打开期间轮询鼠标位置, 干两件事: 离开可交互区就收起、更新高亮的是哪一行。
    // (透明区域已经穿透, 鼠标从那里离开时系统不会再发 mouseExited 给我们;
    //  也正因为窗口大片透明, 靠 mouseMoved 追踪 hover 不如直接问鼠标在哪儿可靠)
    private func startHoverWatch() {
        stopHoverWatch()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let win = self.window else { return }
            let p = self.convert(win.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if !self.isInteractive(at: p) { self.setBubble(false); return }
            let hit = self.bubbleLineRects().firstIndex { $0.contains(p) } ?? -1
            if hit != self.hoveredLine {
                self.hoveredLine = hit
                self.needsDisplay = true
            }
        }
    }

    private func stopHoverWatch() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    func closeBubble() { setBubble(false) }

    override func mouseEntered(with event: NSEvent) { setBubble(true) }
    override func mouseExited(with event: NSEvent)  { setBubble(false) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // 点在气泡的某一行项目上 → 跳到那个终端, 不拖窗口也不收气泡
        if bubbleVisible {
            for (i, r) in bubbleLineRects().enumerated() where r.contains(p) {
                onProjectClick?(i)
                return
            }
        }
        if !waitingProjects.isEmpty { setBubble(!bubbleVisible) }
        super.mouseDown(with: event)   // 不拦截, 保留拖动窗口能力
    }

    // MARK: - 布局计算(draw 和命中测试共用, 避免两处漂移)

    // 宠物本体的绘制矩形(精灵帧优先, 否则 emoji 的外框)
    func petDrawRect() -> NSRect {
        let petH = PetView.petAreaH
        if let frame = frame_ {
            let sz = frame.size
            guard sz.width > 0, sz.height > 0 else { return .zero }
            let scale = min(bounds.width / sz.width, petH / sz.height, 1.0)
            let w = sz.width * scale, h = sz.height * scale
            return NSRect(x: (bounds.width - w) / 2, y: 2, width: w, height: h)
        }
        let size = (emoji as NSString).size(withAttributes: emojiAttrs())
        return NSRect(x: (bounds.width - size.width) / 2, y: 4, width: size.width, height: size.height)
    }

    private func emojiAttrs() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 44)]
    }

    // MARK: - 气泡的样式常量
    //
    // 走 macOS HUD/tooltip 那一套: 深色半透明底 + 细高光描边 + 投影, 而不是纯色块。
    // 深色在浅色和深色桌面上都压得住, 不用跟随系统外观切两套配色。

    private enum Bubble {
        static let padX: CGFloat = 10        // 气泡左右内边距
        static let padY: CGFloat = 7         // 气泡上下内边距
        static let rowGap: CGFloat = 2       // 行与行的间隔
        static let rowPadX: CGFloat = 6      // 行内文字距离行高亮块左右边的距离
        static let rowPadY: CGFloat = 3      // 行高亮块比文字高出来的部分(上下各一份)
        static let corner: CGFloat = 10
        static let rowCorner: CGFloat = 5
        static let dotD: CGFloat = 6         // 状态圆点直径
        static let dotGap: CGFloat = 7       // 圆点到文字的距离
        static let arrowW: CGFloat = 12      // 指向宠物的小三角
        static let arrowH: CGFloat = 6
        static let gapToPet: CGFloat = 6     // 气泡底(含三角)距宠物区顶的空隙
        static let minW: CGFloat = 128
        static let maxW: CGFloat = 300       // 项目名再长也不铺满屏幕, 超出中间省略

        static let bg = NSColor(calibratedWhite: 0.11, alpha: 0.93)
        static let border = NSColor(calibratedWhite: 1.0, alpha: 0.16)
        static let rowHover = NSColor(calibratedWhite: 1.0, alpha: 0.13)
        static let text = NSColor(calibratedWhite: 0.97, alpha: 1.0)
        static let title = NSColor(calibratedWhite: 0.62, alpha: 1.0)
        static let dot = NSColor.systemOrange

        static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        static let titleFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    }

    // 项目名的绘制属性。中间省略 —— 项目名往往前缀相同、尾部才是区分度所在, 砍中间最不伤辨识。
    private func lineAttrs() -> [NSAttributedString.Key: Any] {
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingMiddle
        return [.font: Bubble.font, .foregroundColor: Bubble.text, .paragraphStyle: ps]
    }

    private func titleAttrs() -> [NSAttributedString.Key: Any] {
        [.font: Bubble.titleFont, .foregroundColor: Bubble.title]
    }

    // 多个项目在等时才加一行小标题; 只有一个时标题是废话, 白占高度
    private var bubbleTitle: String? {
        waitingProjects.count > 1 ? "\(waitingProjects.count) 个项目等你确认" : nil
    }

    private var rowH: CGFloat {
        ceil(Bubble.font.ascender - Bubble.font.descender) + Bubble.rowPadY * 2
    }

    private var titleH: CGFloat {
        bubbleTitle == nil ? 0 : ceil(Bubble.titleFont.ascender - Bubble.titleFont.descender) + 4
    }

    // MARK: - 布局计算(draw 和命中测试共用, 避免两处漂移)

    // 气泡的自然宽度。只由文字决定, 不看 bounds —— 否则"窗口按气泡变宽"和
    // "气泡按窗口截断"会互相循环, 长项目名永远被压在初始窗宽里。
    private func bubbleWidth() -> CGFloat {
        guard !waitingProjects.isEmpty else { return 0 }
        let attrs: [NSAttributedString.Key: Any] = [.font: Bubble.font]
        var textW = waitingProjects
            .map { ($0 as NSString).size(withAttributes: attrs).width }
            .max() ?? 0
        if let t = bubbleTitle {
            textW = max(textW, (t as NSString).size(withAttributes: [.font: Bubble.titleFont]).width)
        }
        let full = textW + Bubble.dotD + Bubble.dotGap + Bubble.rowPadX * 2 + Bubble.padX * 2
        return min(max(ceil(full), Bubble.minW), Bubble.maxW)
    }

    private func bubbleHeight() -> CGFloat {
        guard !waitingProjects.isEmpty else { return 0 }
        let n = CGFloat(waitingProjects.count)
        return titleH + rowH * n + Bubble.rowGap * (n - 1) + Bubble.padY * 2
    }

    // 气泡外框(视图坐标), 不含底部三角
    func bubbleRect() -> NSRect {
        let bw = bubbleWidth(), bh = bubbleHeight()
        guard bw > 0 else { return .zero }
        return NSRect(x: (bounds.width - bw) / 2, y: bounds.height - bh - 2, width: bw, height: bh)
    }

    // 命中区比气泡本身大一圈, 向下一直盖到宠物头顶: 鼠标从宠物挪到气泡要穿过中间那段
    // 透明空隙, 不留出余量的话气泡会在半路自己收起来。
    func bubbleHitRect() -> NSRect {
        let box = bubbleRect()
        guard box.width > 0 else { return .zero }
        let bottom = PetView.petAreaH - 8
        return NSRect(x: box.minX - 4, y: bottom,
                      width: box.width + 8, height: box.maxY - bottom + 4)
    }

    // 气泡内每行的矩形(即高亮块的范围), 顺序与 waitingProjects 一致
    func bubbleLineRects() -> [NSRect] {
        let box = bubbleRect()
        guard box.width > 0 else { return [] }
        let top = box.maxY - Bubble.padY - titleH
        return waitingProjects.indices.map { i in
            NSRect(x: box.minX + Bubble.padX,
                   y: top - rowH * CGFloat(i + 1) - Bubble.rowGap * CGFloat(i),
                   width: box.width - Bubble.padX * 2,
                   height: rowH)
        }
    }

    // 期望窗口尺寸: 无气泡时只需宠物区; 有气泡时还要容得下气泡的宽和高
    func desiredSize() -> NSSize {
        let baseW = PetView.baseWidth
        guard bubbleVisible, !waitingProjects.isEmpty else {
            return NSSize(width: baseW, height: PetView.petAreaH + 4)
        }
        return NSSize(width: max(baseW, bubbleWidth() + 8),
                      height: PetView.petAreaH + Bubble.gapToPet + Bubble.arrowH + bubbleHeight())
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        // 宠物本体: 固定画在底部 petAreaH 区域内(精灵帧优先, 否则 emoji)
        let r = petDrawRect()
        if let frame = frame_ {
            frame.draw(in: r)
        } else {
            (emoji as NSString).draw(at: r.origin, withAttributes: emojiAttrs())
        }

        // 气泡: 仅在悬停/点击且有等待项目时显示; 逐行列出全部项目, 位于宠物上方不重叠
        guard bubbleVisible, !waitingProjects.isEmpty else { return }
        let box = bubbleRect()
        guard box.width > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()

        // 圆角框 + 底部指向宠物的小三角, 合成一条路径一起填充, 免得接缝处透出投影
        let path = NSBezierPath(roundedRect: box, xRadius: Bubble.corner, yRadius: Bubble.corner)
        let cx = box.midX
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: cx - Bubble.arrowW / 2, y: box.minY + 1))
        arrow.line(to: NSPoint(x: cx, y: box.minY - Bubble.arrowH))
        arrow.line(to: NSPoint(x: cx + Bubble.arrowW / 2, y: box.minY + 1))
        arrow.close()
        path.append(arrow)
        Bubble.bg.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        // 细高光描边(只描圆角框, 不描三角 —— 三角上那道边会横穿气泡底显得脏)
        Bubble.border.setStroke()
        let stroke = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: Bubble.corner, yRadius: Bubble.corner)
        stroke.lineWidth = 1
        stroke.stroke()

        if let t = bubbleTitle {
            (t as NSString).draw(
                at: NSPoint(x: box.minX + Bubble.padX + Bubble.rowPadX,
                            y: box.maxY - Bubble.padY - titleH + 2),
                withAttributes: titleAttrs())
        }

        let attrs = lineAttrs()
        for (i, lr) in bubbleLineRects().enumerated() {
            if i == hoveredLine {
                Bubble.rowHover.setFill()
                NSBezierPath(roundedRect: lr, xRadius: Bubble.rowCorner, yRadius: Bubble.rowCorner).fill()
            }
            // 状态圆点: 垂直居中于本行
            Bubble.dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: lr.minX + Bubble.rowPadX,
                                        y: lr.midY - Bubble.dotD / 2,
                                        width: Bubble.dotD, height: Bubble.dotD)).fill()
            let textX = lr.minX + Bubble.rowPadX + Bubble.dotD + Bubble.dotGap
            (waitingProjects[i] as NSString).draw(
                in: NSRect(x: textX, y: lr.minY + Bubble.rowPadY,
                           width: lr.maxX - Bubble.rowPadX - textX,
                           height: lr.height - Bubble.rowPadY * 2),
                withAttributes: attrs)
        }
    }
}

class PetController {
    private var window: NSWindow?
    private let view = PetView()
    private let baseSize = NSSize(width: PetView.baseWidth, height: 156)  // 无气泡时: 底部宠物区
    private let posPath = home.appendingPathComponent(".claude/pet-pos.json")
    private var suppressPositionSave = false   // 见 resizeKeepingBottomCenter
    private var sprite: SpriteSheet?
    private var animTimer: Timer?
    private var timerInterval: TimeInterval = 0   // animTimer 当前的间隔, 用来判断要不要重建
    private var currentSpritePath: String?

    // 常态动画/表情 与 一次性动画(庆祝、提醒), 后者在时长内覆盖前者
    private var baseAnim: PetAnim = .idle
    private var baseEmoji = "🐣"
    private var transientAnim: PetAnim?
    private var transientEmoji: String?
    private var transientTimer: Timer?

    // 点了气泡里第 i 行项目时回调(由 AppDelegate 注入, 每次刷新重新绑定当前等待列表)
    var onProjectClick: ((Int) -> Void)? {
        get { view.onProjectClick }
        set { view.onProjectClick = newValue }
    }

    // 显示宠物窗口(幂等)
    func show() {
        if window != nil { return }
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: baseSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating                       // 浮在普通窗口之上
        w.isMovableByWindowBackground = true      // 拖背景即可移动窗口
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary] // 所有桌面/全屏都跟随
        w.ignoresMouseEvents = false              // 逐像素穿透由 PetView.hitTest 决定
        view.frame = NSRect(origin: .zero, size: baseSize)
        w.contentView = view
        w.setFrameOrigin(loadPosition())
        w.orderFrontRegardless()
        window = w

        // 气泡展开/收起时伸缩窗口: 底边和水平中心都不动, 所以宠物看上去纹丝不动,
        // 只有气泡在它头顶长出来。
        view.onDesiredSizeChange = { [weak self] size in
            self?.resizeKeepingBottomCenter(to: size)
        }

        // 拖动结束后记住位置
        NotificationCenter.default.addObserver(
            self, selector: #selector(savePosition),
            name: NSWindow.didMoveNotification, object: w)
    }

    // 改变窗口尺寸但保持底边和水平中心不动。
    // 期间要抑制位置持久化: setFrame 会触发 didMoveNotification, 不拦的话气泡撑宽窗口
    // 时那个临时 origin 会被存下来, 宠物每开合一次就往旁边挪一点。
    private func resizeKeepingBottomCenter(to size: NSSize) {
        guard let w = window else { return }
        let old = w.frame
        guard abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5 else { return }
        let f = NSRect(x: (old.midX - size.width / 2).rounded(),
                       y: old.minY,
                       width: size.width, height: size.height)
        suppressPositionSave = true
        w.setFrame(f, display: true)
        suppressPositionSave = false
        view.frame = NSRect(origin: .zero, size: f.size)
        view.needsDisplay = true
    }

    func hide() {
        if let w = window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: w)
            w.orderOut(nil)
        }
        window = nil
        animTimer?.invalidate()
        animTimer = nil
        transientTimer?.invalidate()
        transientTimer = nil
        transientAnim = nil
        transientEmoji = nil
        view.closeBubble()
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
            view.mask = nil
        }
        apply()
    }

    // 帧率跟着状态走(跑动比待机快), 所以定时器间隔在状态切换时可能要换 —— 见 syncAnimTimer()
    private func startAnimating() {
        guard let sp = sprite else { return }
        animTimer?.invalidate()
        timerInterval = sp.currentInterval
        animTimer = Timer.scheduledTimer(withTimeInterval: timerInterval, repeats: true) { [weak self] _ in
            guard let self = self, let sp = self.sprite, self.window != nil else { return }
            sp.advance()
            self.view.frame_ = sp.currentFrame()
            self.view.mask = sp.currentMask()
            self.view.needsDisplay = true
        }
    }

    // 当前状态要求的帧间隔和定时器不一致时重建定时器(状态切换后调一次即可)
    private func syncAnimTimer() {
        guard let sp = sprite, animTimer != nil, sp.currentInterval != timerInterval else { return }
        startAnimating()
    }

    // 更新: emoji 回退文案 + 常态动画 + 等待项目列表(气泡内容, 按需显示)
    func update(emoji: String, anim: PetAnim, waitingProjects: [String]) {
        baseEmoji = emoji
        baseAnim = anim
        view.waitingProjects = waitingProjects
        if waitingProjects.isEmpty && view.bubbleVisible {
            view.closeBubble()                  // 没等待项目 → 收起气泡
            resizeKeepingBottomCenter(to: view.desiredSize())
        }
        apply()
    }

    // 播放一次性动画(如完成时挥手庆祝、新等待时跳一下), duration 后自动回到常态
    func playOnce(_ anim: PetAnim, emoji: String, duration: TimeInterval) {
        guard window != nil else { return }
        transientTimer?.invalidate()
        transientAnim = anim
        transientEmoji = emoji
        transientTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.transientAnim = nil
            self.transientEmoji = nil
            self.transientTimer = nil
            self.apply()
        }
        apply()
    }

    // 把"一次性动画优先于常态"的结果落到视图上
    private func apply() {
        view.emoji = transientEmoji ?? baseEmoji
        if let sp = sprite {
            sp.setState(transientAnim ?? baseAnim)
            syncAnimTimer()
            view.frame_ = sp.currentFrame()
            view.mask = sp.currentMask()
        } else {
            view.frame_ = nil
            view.mask = nil
        }
        view.needsDisplay = true
    }

    // MARK: - 位置持久化
    @objc private func savePosition() {
        guard !suppressPositionSave, let origin = window?.frame.origin else { return }
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
            return NSPoint(x: vf.maxX - baseSize.width - 40, y: vf.minY + 40)
        }
        return NSPoint(x: 200, y: 200)
    }
}

import AppKit
import SpriteKit
import NeuroFlyCore

final class DesktopSKView: SKView {
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class DesktopPetScene: SKScene {
    private let flyNode = FlyNode()
    private let foodLayer = SKNode()
    private let shadowNode = ShadowNode()
    private let placementHintPanel = SKShapeNode(rectOf: CGSize(width: 350, height: 44), cornerRadius: 12)
    private let placementHintLabel = SKLabelNode(fontNamed: "SFProRounded-Semibold")
    private var foodNodes: [UUID: FoodNode] = [:]

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        anchorPoint = .zero
        backgroundColor = .clear
        addChild(foodLayer)
        foodLayer.zPosition = 2
        addChild(shadowNode)
        shadowNode.zPosition = 3
        addChild(flyNode)
        flyNode.zPosition = 10
        setupPlacementHint()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        scaleMode = .resizeFill
        anchorPoint = .zero
        backgroundColor = .clear
        addChild(foodLayer)
        foodLayer.zPosition = 2
        addChild(shadowNode)
        shadowNode.zPosition = 3
        addChild(flyNode)
        flyNode.zPosition = 10
        setupPlacementHint()
    }

    func apply(_ snapshot: WorldSnapshot) {
        let width = max(1, snapshot.width)
        let height = max(1, snapshot.height)
        flyNode.apply(snapshot.fly, elapsed: snapshot.elapsed)
        flyNode.position = CGPoint(x: snapshot.fly.position.x / width * Double(size.width),
                                   y: snapshot.fly.position.y / height * Double(size.height))

        let ids = Set(snapshot.foods.map(\.id))
        for (id, node) in foodNodes where !ids.contains(id) {
            node.removeFromParent()
            foodNodes.removeValue(forKey: id)
        }
        for food in snapshot.foods {
            let node: FoodNode
            if let existing = foodNodes[food.id] {
                node = existing
            } else {
                node = FoodNode()
                foodNodes[food.id] = node
                foodLayer.addChild(node)
            }
            node.position = CGPoint(x: food.position.x / width * Double(size.width),
                                    y: food.position.y / height * Double(size.height))
            let localFood = FoodItem(id: food.id, position: Point2(x: node.position.x, y: node.position.y), remaining: food.remaining)
            node.apply(localFood)
        }

        if let shadowPosition = snapshot.shadowPosition, snapshot.shadowStrength > 0.001 {
            shadowNode.isHidden = false
            shadowNode.apply(position: Point2(x: shadowPosition.x / width * Double(size.width),
                                              y: shadowPosition.y / height * Double(size.height)),
                             strength: snapshot.shadowStrength, elapsed: snapshot.elapsed)
        } else {
            shadowNode.isHidden = true
        }
    }

    func showPlacementHint(for tool: ArenaTool) {
        placementHintLabel.text = "화면을 클릭해 \(tool.title) · Escape로 취소"
        placementHintPanel.isHidden = false
        updatePlacementHintPosition()
    }

    func hidePlacementHint() {
        placementHintPanel.isHidden = true
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        updatePlacementHintPosition()
    }

    private func setupPlacementHint() {
        placementHintPanel.fillColor = NeuroFlyStyle.skCanvas.withAlphaComponent(0.90)
        placementHintPanel.strokeColor = NeuroFlyStyle.skMint.withAlphaComponent(0.72)
        placementHintPanel.lineWidth = 1
        placementHintPanel.zPosition = 100
        placementHintPanel.isHidden = true
        addChild(placementHintPanel)

        placementHintLabel.fontSize = 12
        placementHintLabel.fontColor = NeuroFlyStyle.skCream
        placementHintLabel.horizontalAlignmentMode = .center
        placementHintLabel.verticalAlignmentMode = .center
        placementHintPanel.addChild(placementHintLabel)
    }

    private func updatePlacementHintPosition() {
        placementHintPanel.position = CGPoint(x: size.width / 2, y: max(40, size.height - 54))
    }
}

@MainActor
final class DesktopModeController: NSObject, NSWindowDelegate {
    var onAction: ((UserAction) -> Void)?
    var onBackToArena: (() -> Void)?
    var onShowBrain: (() -> Void)?
    var onResize: ((CGSize) -> Void)?

    private(set) var isActive = false
    private(set) var isPetVisible = true

    private var overlayWindow: DesktopOverlayWindow?
    private var controlPanel: DesktopControlPanel?
    private let scene = DesktopPetScene(size: CGSize(width: 1440, height: 900))
    private var latestSnapshot = WorldSnapshot()
    private var selectedTool: ArenaTool = .food
    private var placementMode = false
    private var lastNotifiedResize = CGSize.zero

    func start(with snapshot: WorldSnapshot, showControlPanel: Bool = false) {
        isActive = true
        isPetVisible = true
        latestSnapshot = snapshot
        if overlayWindow == nil {
            createOverlay()
        }
        if showControlPanel, controlPanel == nil {
            createControlPanel()
        }
        updateScreenFrame()
        if let frame = overlayWindow?.frame, frame.width > 0, frame.height > 0 {
            notifyResize(frame.size)
        }
        overlayWindow?.ignoresMouseEvents = true
        overlayWindow?.orderFrontRegardless()
        controlPanel?.setPlacementMode(false)
        if showControlPanel {
            controlPanel?.orderFrontRegardless()
        } else {
            controlPanel?.orderOut(nil)
        }
        render(snapshot)
    }

    func stop() {
        isActive = false
        placementMode = false
        scene.hidePlacementHint()
        overlayWindow?.ignoresMouseEvents = true
        overlayWindow?.orderOut(nil)
        controlPanel?.orderOut(nil)
        overlayWindow = nil
        controlPanel = nil
        lastNotifiedResize = .zero
    }

    func setPetVisible(_ visible: Bool) {
        isPetVisible = visible
        guard isActive else { return }
        if visible {
            overlayWindow?.orderFrontRegardless()
        } else {
            placementMode = false
            scene.hidePlacementHint()
            overlayWindow?.ignoresMouseEvents = true
            overlayWindow?.orderOut(nil)
        }
    }

    func armPlacement(for tool: ArenaTool) {
        guard isActive else { return }
        selectedTool = tool
        isPetVisible = true
        placementMode = true
        scene.showPlacementHint(for: tool)
        overlayWindow?.ignoresMouseEvents = false
        overlayWindow?.orderFrontRegardless()
        overlayWindow?.makeKeyAndOrderFront(nil)
        overlayWindow?.contentView?.window?.makeFirstResponder(overlayWindow?.contentView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func render(_ snapshot: WorldSnapshot) {
        latestSnapshot = snapshot
        updateScreenFrame()
        scene.apply(snapshot)
        controlPanel?.update(snapshot)
    }

    func setTool(_ tool: ArenaTool) {
        selectedTool = tool
        controlPanel?.setTool(tool)
    }

    private func createOverlay() {
        let frame = screenFrame()
        let window = DesktopOverlayWindow(contentRect: NSRect(origin: .zero, size: frame.size),
                                          styleMask: .borderless,
                                          backing: .buffered,
                                          defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.delegate = self

        let view = DesktopSKView(frame: frame)
        view.allowsTransparency = true
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.preferredFramesPerSecond = 60
        view.ignoresSiblingOrder = true
        view.presentScene(scene)
        view.onEscape = { [weak self] in self?.finishPlacement() }
        window.contentView = view
        overlayWindow = window
    }

    private func createControlPanel() {
        let panel = DesktopControlPanel()
        panel.onPlacement = { [weak self] in self?.beginPlacement() }
        panel.onTool = { [weak self] tool in self?.setTool(tool) }
        panel.onClear = { [weak self] in self?.onAction?(.clearFood) }
        panel.onBack = { [weak self] in self?.onBackToArena?() }
        panel.onShowBrain = { [weak self] in self?.onShowBrain?() }
        panel.onEscape = { [weak self] in self?.finishPlacement() }
        panel.delegate = self
        controlPanel = panel
    }

    private func beginPlacement() {
        guard overlayWindow != nil else { return }
        armPlacement(for: selectedTool)
        controlPanel?.setPlacementMode(true)
    }

    private func finishPlacement() {
        guard placementMode else { return }
        placementMode = false
        scene.hidePlacementHint()
        overlayWindow?.ignoresMouseEvents = true
        controlPanel?.setPlacementMode(false)
        if isPetVisible {
            overlayWindow?.orderFrontRegardless()
        } else {
            overlayWindow?.orderOut(nil)
        }
        if controlPanel != nil {
            controlPanel?.orderFrontRegardless()
        }
    }

    private func handlePlacement(at point: CGPoint) {
        guard placementMode, let frame = overlayWindow?.frame else { return }
        let x = max(0, min(frame.width, point.x))
        let y = max(0, min(frame.height, point.y))
        let width = max(1, latestSnapshot.width)
        let height = max(1, latestSnapshot.height)
        let modelPoint = Point2(x: Double(x / frame.width) * width,
                                y: Double(y / frame.height) * height)
        switch selectedTool {
        case .food:
            onAction?(.placeFood(modelPoint))
        case .shadow:
            onAction?(.castShadow(modelPoint))
        case .touch:
            onAction?(.touchFly)
        }
        finishPlacement()
    }

    private func updateScreenFrame() {
        guard let window = overlayWindow else { return }
        let frame = screenFrame()
        if window.frame != frame {
            window.setFrame(frame, display: false)
            scene.size = frame.size
            if isActive {
                notifyResize(frame.size)
            }
        }
    }

    private func notifyResize(_ size: CGSize) {
        guard size.width > 0, size.height > 0,
              abs(size.width - lastNotifiedResize.width) > 0.1 || abs(size.height - lastNotifiedResize.height) > 0.1 else { return }
        lastNotifiedResize = size
        onResize?(size)
    }

    private func screenFrame() -> NSRect {
        NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === controlPanel {
            onBackToArena?()
            return false
        }
        return true
    }
}

final class DesktopOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let sceneView = contentView as? DesktopSKView,
           let scene = sceneView.scene,
           let controller = delegate as? DesktopModeController {
            controller.handlePlacementFromScene(scene, event: event)
        }
        super.sendEvent(event)
    }
}

@MainActor
private extension DesktopModeController {
    func handlePlacementFromScene(_ scene: SKScene, event: NSEvent) {
        guard placementMode else { return }
        let point = event.location(in: scene)
        handlePlacement(at: point)
    }
}

@MainActor
final class DesktopControlPanel: NSPanel {
    var onPlacement: (() -> Void)?
    var onTool: ((ArenaTool) -> Void)?
    var onClear: (() -> Void)?
    var onBack: (() -> Void)?
    var onShowBrain: (() -> Void)?
    var onEscape: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "통과 모드 · 화면 클릭은 원래 앱으로 전달됩니다")
    private let placementButton = NSButton(title: "클릭으로 배치", target: nil, action: nil)
    private var toolButtons: [ArenaTool: NSButton] = [:]
    private var placementActive = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 350, height: 210),
                   styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = "NeuroFly · 데스크톱 펫"
        appearance = NSAppearance(named: .darkAqua)
        isReleasedWhenClosed = false
        level = .statusBar
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        buildView()
    }

    func update(_ snapshot: WorldSnapshot) {
        let model = snapshot.error == nil ? (snapshot.isReady ? "신경망 연결됨" : "신경망 초기화 중") : "오류: \(snapshot.error ?? "알 수 없음")"
        statusLabel.stringValue = placementActive ? model + " · 배치 중 — Escape로 취소" : model + " · 통과 모드"
        statusLabel.textColor = snapshot.error == nil ? NeuroFlyStyle.mutedInk : NeuroFlyStyle.coral
    }

    func setTool(_ tool: ArenaTool) {
        for (candidate, button) in toolButtons {
            button.state = candidate == tool ? .on : .off
            button.contentTintColor = candidate == tool ? NeuroFlyStyle.cream : NeuroFlyStyle.ink
        }
    }

    func setPlacementMode(_ active: Bool) {
        placementActive = active
        placementButton.title = active ? "배치 중 · Escape로 취소" : "클릭으로 배치"
        placementButton.contentTintColor = active ? NeuroFlyStyle.orange : NeuroFlyStyle.mint
        placementButton.isEnabled = true
        statusLabel.stringValue = active ? "배치 중 · 화면의 위치를 클릭하세요" : "통과 모드 · 화면 클릭은 원래 앱으로 전달됩니다"
    }

    private func buildView() {
        guard let content = contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NeuroFlyStyle.canvas.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let titleLabel = NSTextField(labelWithString: "데스크톱 펫")
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = NeuroFlyStyle.cream
        stack.addArrangedSubview(titleLabel)

        statusLabel.font = .systemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = NeuroFlyStyle.mutedInk
        statusLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(statusLabel)

        let tools = NSStackView()
        tools.orientation = .horizontal
        tools.spacing = 5
        for tool in ArenaTool.allCases {
            let button = NSButton(title: tool.shortTitle, target: self, action: #selector(toolPressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            button.setButtonType(.radio)
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.contentTintColor = NeuroFlyStyle.ink
            button.widthAnchor.constraint(equalToConstant: tool == .touch ? 76 : 60).isActive = true
            tools.addArrangedSubview(button)
            toolButtons[tool] = button
        }
        stack.addArrangedSubview(tools)

        placementButton.target = self
        placementButton.action = #selector(placementPressed)
        placementButton.bezelStyle = .rounded
        placementButton.controlSize = .regular
        placementButton.font = .systemFont(ofSize: 11, weight: .semibold)
        placementButton.contentTintColor = NeuroFlyStyle.mint
        stack.addArrangedSubview(placementButton)

        let lower = NSStackView()
        lower.orientation = .horizontal
        lower.spacing = 6
        let clear = NSButton(title: "비우기", target: self, action: #selector(clearPressed))
        clear.bezelStyle = .texturedRounded
        clear.controlSize = .small
        lower.addArrangedSubview(clear)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        lower.addArrangedSubview(spacer)
        let brain = NSButton(title: "뇌 보기", target: self, action: #selector(brainPressed))
        brain.bezelStyle = .texturedRounded
        brain.controlSize = .small
        lower.addArrangedSubview(brain)
        let back = NSButton(title: "아레나로 돌아가기", target: self, action: #selector(backPressed))
        back.bezelStyle = .texturedRounded
        back.controlSize = .small
        lower.addArrangedSubview(back)
        stack.addArrangedSubview(lower)
        setTool(.food)
    }

    @objc private func placementPressed() { onPlacement?() }

    @objc private func toolPressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let tool = ArenaTool(rawValue: raw) else { return }
        onTool?(tool)
    }

    @objc private func clearPressed() { onClear?() }
    @objc private func brainPressed() { onShowBrain?() }
    @objc private func backPressed() { onBack?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

import AppKit
import SpriteKit
import NeuroFlyCore

/// An SKView that can receive Escape even when the scene has no active tool.
final class ArenaSKView: SKView {
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

/// The arena is a renderer and input surface. It never decides where a fly should go;
/// every position and activity value comes from WorldSnapshot.
@MainActor
final class ArenaScene: SKScene {
    var onArenaClick: ((Point2) -> Void)?
    var onEscape: (() -> Void)?

    private var currentSnapshot = WorldSnapshot()
    private var currentTool: ArenaTool = .food
    private var lastSize = CGSize.zero

    private let gridNode = SKNode()
    private let foodLayer = SKNode()
    private let effectLayer = SKNode()
    private var flyNodes: [UUID: FlyNode] = [:]
    private let legacyIndividualID = UUID()
    private let shadowNode = ShadowNode()
    private let statusPanel = SKShapeNode(rectOf: CGSize(width: 480, height: 72), cornerRadius: 14)
    private let statusLabel = SKLabelNode(fontNamed: "SFProRounded-Semibold")
    private let statusDetailLabel = SKLabelNode(fontNamed: "SFProText-Regular")
    private let errorLabel = SKLabelNode(fontNamed: "SFProText-Regular")
    private let hintLabel = SKLabelNode(fontNamed: "SFProText-Regular")
    private let fieldCaption = SKLabelNode(fontNamed: "SFProRounded-Semibold")
    private var foodNodes: [UUID: FoodNode] = [:]
    private var isReadyForInput = false

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = NeuroFlyStyle.skCanvas
        anchorPoint = .zero
        setupNodes()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        scaleMode = .resizeFill
        backgroundColor = NeuroFlyStyle.skCanvas
        anchorPoint = .zero
        setupNodes()
    }

    private func setupNodes() {
        gridNode.zPosition = -20
        addChild(gridNode)

        let backdrop = SKShapeNode(rectOf: CGSize(width: 1000, height: 650), cornerRadius: 20)
        backdrop.name = "arenaBackdrop"
        backdrop.fillColor = NeuroFlyStyle.skCanvasRaised
        backdrop.strokeColor = NeuroFlyStyle.skCanvasLine
        backdrop.lineWidth = 1
        backdrop.position = CGPoint(x: 500, y: 325)
        backdrop.zPosition = -30
        addChild(backdrop)

        addChild(foodLayer)
        foodLayer.zPosition = 2
        addChild(effectLayer)
        effectLayer.zPosition = 3
        effectLayer.addChild(shadowNode)
        fieldCaption.text = "CLOSED LOOP ARENA"
        fieldCaption.fontSize = 10
        fieldCaption.fontColor = NeuroFlyStyle.skCream.withAlphaComponent(0.54)
        fieldCaption.horizontalAlignmentMode = .left
        fieldCaption.verticalAlignmentMode = .center
        fieldCaption.position = CGPoint(x: 30, y: 24)
        fieldCaption.zPosition = 5
        addChild(fieldCaption)

        hintLabel.fontSize = 12
        hintLabel.fontColor = NeuroFlyStyle.skCream.withAlphaComponent(0.74)
        hintLabel.horizontalAlignmentMode = .right
        hintLabel.verticalAlignmentMode = .center
        hintLabel.zPosition = 5
        addChild(hintLabel)

        statusPanel.fillColor = NeuroFlyStyle.skCanvas.withAlphaComponent(0.94)
        statusPanel.strokeColor = NeuroFlyStyle.skMint.withAlphaComponent(0.38)
        statusPanel.lineWidth = 1
        statusPanel.zPosition = 20
        addChild(statusPanel)

        statusLabel.fontSize = 13
        statusLabel.fontColor = NeuroFlyStyle.skCream
        statusLabel.horizontalAlignmentMode = .left
        statusLabel.verticalAlignmentMode = .center
        statusPanel.addChild(statusLabel)
        statusLabel.position = CGPoint(x: -215, y: 11)

        statusDetailLabel.fontSize = 10
        statusDetailLabel.fontColor = NeuroFlyStyle.skCream.withAlphaComponent(0.66)
        statusDetailLabel.horizontalAlignmentMode = .left
        statusDetailLabel.verticalAlignmentMode = .center
        statusPanel.addChild(statusDetailLabel)
        statusDetailLabel.position = CGPoint(x: -215, y: -11)

        errorLabel.fontSize = 10
        errorLabel.fontColor = NeuroFlyStyle.skCoral
        errorLabel.horizontalAlignmentMode = .left
        errorLabel.verticalAlignmentMode = .center
        statusPanel.addChild(errorLabel)
        errorLabel.position = CGPoint(x: -215, y: -28)

        isReadyForInput = true
        updateSceneSize()
    }

    func setTool(_ tool: ArenaTool) {
        currentTool = tool
        hintLabel.text = tool.hint
    }

    func apply(_ snapshot: WorldSnapshot) {
        currentSnapshot = snapshot
        if size.width > 0, size.height > 0, size != lastSize {
            updateSceneSize()
        }

        renderFlies(snapshot)
        renderFoods(snapshot)
        renderShadow(snapshot)
        renderStatus(snapshot)
    }

    private func updateSceneSize() {
        guard size.width > 0, size.height > 0 else { return }
        lastSize = size
        let backdrop = childNode(withName: "arenaBackdrop") as? SKShapeNode
        backdrop?.path = CGPath(roundedRect: CGRect(x: -size.width / 2, y: -size.height / 2,
                                                    width: size.width, height: size.height),
                                 cornerWidth: 20, cornerHeight: 20, transform: nil)
        backdrop?.position = CGPoint(x: size.width / 2, y: size.height / 2)
        buildGrid()
        statusPanel.position = CGPoint(x: 250, y: size.height - 64)
        hintLabel.position = CGPoint(x: size.width - 30, y: 24)
        fieldCaption.position = CGPoint(x: 30, y: 24)
        renderStatus(currentSnapshot)
    }

    private func buildGrid() {
        gridNode.removeAllChildren()
        let step: CGFloat = 64
        var x: CGFloat = 0
        while x <= size.width {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            let line = SKShapeNode(path: path)
            line.strokeColor = NeuroFlyStyle.skCanvasLine
            line.lineWidth = 0.5
            gridNode.addChild(line)
            x += step
        }
        var y: CGFloat = 0
        while y <= size.height {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            let line = SKShapeNode(path: path)
            line.strokeColor = NeuroFlyStyle.skCanvasLine
            line.lineWidth = 0.5
            gridNode.addChild(line)
            y += step
        }

        for point in stride(from: CGFloat(32), through: size.width, by: 128) {
            let dot = SKShapeNode(circleOfRadius: 1.5)
            dot.position = CGPoint(x: point, y: 32)
            dot.fillColor = NeuroFlyStyle.skMint.withAlphaComponent(0.25)
            dot.strokeColor = .clear
            gridNode.addChild(dot)
        }
    }

    private func renderFoods(_ snapshot: WorldSnapshot) {
        let foods = snapshot.foods
        let ids = Set(foods.map(\.id))
        for (id, node) in foodNodes where !ids.contains(id) {
            node.removeFromParent()
            foodNodes.removeValue(forKey: id)
        }

        for food in foods {
            let node: FoodNode
            if let existing = foodNodes[food.id] {
                node = existing
            } else {
                node = FoodNode()
                foodNodes[food.id] = node
                foodLayer.addChild(node)
            }
            node.apply(food)
            node.position = CGPoint(x: food.position.x / max(1, snapshot.width) * Double(size.width),
                                    y: food.position.y / max(1, snapshot.height) * Double(size.height))
        }
    }

    private func renderFlies(_ snapshot: WorldSnapshot) {
        let individuals = neuroFlyRenderIndividuals(snapshot, legacyID: legacyIndividualID)
        let ids = Set(individuals.map(\.id))
        for (id, node) in flyNodes where !ids.contains(id) {
            node.removeFromParent()
            flyNodes.removeValue(forKey: id)
        }

        let showLabels = individuals.count > 1
        let width = max(1, snapshot.width)
        let height = max(1, snapshot.height)
        for individual in individuals {
            let node: FlyNode
            if let existing = flyNodes[individual.id] {
                node = existing
            } else {
                node = FlyNode()
                flyNodes[individual.id] = node
                addChild(node)
            }
            node.apply(individual.fly,
                       elapsed: snapshot.elapsed,
                       phaseOffset: Double(individual.ordinal) * 0.73,
                       accent: NeuroFlyStyle.skIndividualColor(ordinal: individual.ordinal),
                       selected: individual.isSelected,
                       ordinal: individual.ordinal + 1,
                       showIdentity: showLabels)
            node.position = CGPoint(x: individual.fly.position.x / width * Double(size.width),
                                    y: individual.fly.position.y / height * Double(size.height))
            node.zPosition = individual.isSelected ? 12 : 10
        }
    }

    private func renderShadow(_ snapshot: WorldSnapshot) {
        guard let position = snapshot.shadowPosition, snapshot.shadowStrength > 0.001 else {
            shadowNode.isHidden = true
            return
        }
        shadowNode.isHidden = false
        let scenePosition = Point2(x: position.x / max(1, snapshot.width) * Double(size.width),
                                   y: position.y / max(1, snapshot.height) * Double(size.height))
        shadowNode.apply(position: scenePosition, strength: snapshot.shadowStrength, elapsed: snapshot.elapsed)
    }

    private func renderStatus(_ snapshot: WorldSnapshot) {
        let hasError = snapshot.error != nil
        let isRunning = snapshot.isReady && !snapshot.isPaused
        let individuals = neuroFlyRenderIndividuals(snapshot, legacyID: legacyIndividualID)
        let selectedOrdinal = individuals.first(where: { $0.isSelected })?.ordinal ?? 0
        let dataset = snapshot.brainModel.displayName
        statusLabel.text = snapshot.error == nil ? (snapshot.isPaused ? "일시정지" : (snapshot.isReady ? "신경망 연결됨" : "준비 중")) : "신경망을 확인하세요"
        statusLabel.fontColor = hasError ? NeuroFlyStyle.skCoral : (isRunning ? NeuroFlyStyle.skMint : NeuroFlyStyle.skCream)
        statusDetailLabel.text = snapshot.error == nil
            ? "\(dataset) · 선택 개체 #\(selectedOrdinal + 1) · 총 \(individuals.count)개 · \(snapshot.status)"
            : "\(dataset) · 로컬 모델을 불러오는 동안 문제가 발생했습니다"
        errorLabel.text = snapshot.error.map { String($0.prefix(62)) } ?? ""
        statusPanel.strokeColor = hasError ? NeuroFlyStyle.skCoral.withAlphaComponent(0.64) : NeuroFlyStyle.skMint.withAlphaComponent(0.38)
        statusPanel.alpha = snapshot.isReady && snapshot.error == nil ? 0.78 : 1
    }

    override func mouseDown(with event: NSEvent) {
        guard isReadyForInput else { return }
        let point = event.location(in: self)
        guard point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return }
        onArenaClick?(Point2(x: Double(point.x), y: Double(point.y)))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

/// A compact but recognizable fruit fly assembled entirely from vector SpriteKit nodes.
final class FlyNode: SKNode {
    private let aura = SKShapeNode(circleOfRadius: 32)
    private let selectionRing = SKShapeNode(circleOfRadius: 38)
    private let abdomen = SKShapeNode(ellipseOf: CGSize(width: 31, height: 19))
    private let thorax = SKShapeNode(ellipseOf: CGSize(width: 17, height: 17))
    private let head = SKShapeNode(ellipseOf: CGSize(width: 13, height: 13))
    private let eyeTop = SKShapeNode(circleOfRadius: 3.5)
    private let eyeBottom = SKShapeNode(circleOfRadius: 3.5)
    private let leftWing = SKShapeNode()
    private let rightWing = SKShapeNode()
    private let proboscis = SKShapeNode()
    private let identityLabel = SKLabelNode(fontNamed: "SFProRounded-Semibold")
    private var legs: [SKShapeNode] = []
    private var stripes: [SKShapeNode] = []

    override init() {
        super.init()
        name = "fly"
        setup()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }

    private func setup() {
        aura.fillColor = NeuroFlyStyle.skMint.withAlphaComponent(0.05)
        aura.strokeColor = NeuroFlyStyle.skMint.withAlphaComponent(0.25)
        aura.lineWidth = 1
        addChild(aura)

        selectionRing.fillColor = .clear
        selectionRing.strokeColor = NeuroFlyStyle.skMint.withAlphaComponent(0.78)
        selectionRing.lineWidth = 1.4
        selectionRing.isHidden = true
        addChild(selectionRing)

        abdomen.position = CGPoint(x: -5, y: 0)
        abdomen.fillColor = SKColor(calibratedRed: 0.24, green: 0.15, blue: 0.12, alpha: 1)
        abdomen.strokeColor = NeuroFlyStyle.skCream.withAlphaComponent(0.45)
        abdomen.lineWidth = 0.8
        addChild(abdomen)

        for x in [-13.0, -5.0, 3.0] {
            let stripe = SKShapeNode(rectOf: CGSize(width: 2.3, height: 16), cornerRadius: 1)
            stripe.position = CGPoint(x: x, y: 0)
            stripe.fillColor = NeuroFlyStyle.skCream.withAlphaComponent(0.34)
            stripe.strokeColor = .clear
            stripe.zRotation = -0.08
            stripes.append(stripe)
            addChild(stripe)
        }

        thorax.position = CGPoint(x: 8, y: 0)
        thorax.fillColor = SKColor(calibratedRed: 0.42, green: 0.27, blue: 0.18, alpha: 1)
        thorax.strokeColor = NeuroFlyStyle.skCream.withAlphaComponent(0.52)
        thorax.lineWidth = 0.8
        addChild(thorax)

        head.position = CGPoint(x: 17, y: 0)
        head.fillColor = SKColor(calibratedRed: 0.12, green: 0.09, blue: 0.10, alpha: 1)
        head.strokeColor = NeuroFlyStyle.skCream.withAlphaComponent(0.50)
        head.lineWidth = 0.8
        addChild(head)

        eyeTop.position = CGPoint(x: 20, y: 4)
        eyeBottom.position = CGPoint(x: 20, y: -4)
        for eye in [eyeTop, eyeBottom] {
            eye.fillColor = NeuroFlyStyle.skCoral
            eye.strokeColor = NeuroFlyStyle.skCream.withAlphaComponent(0.75)
            eye.lineWidth = 0.5
            addChild(eye)
        }

        leftWing.path = wingPath(upper: true)
        rightWing.path = wingPath(upper: false)
        for wing in [leftWing, rightWing] {
            wing.fillColor = NeuroFlyStyle.skCream.withAlphaComponent(0.20)
            wing.strokeColor = NeuroFlyStyle.skCream.withAlphaComponent(0.68)
            wing.lineWidth = 0.8
            addChild(wing)
        }
        leftWing.position = CGPoint(x: 7, y: 5)
        rightWing.position = CGPoint(x: 7, y: -5)

        proboscis.path = linePath(from: CGPoint(x: 21, y: 0), to: CGPoint(x: 28, y: 0))
        proboscis.strokeColor = NeuroFlyStyle.skCream
        proboscis.lineWidth = 1
        proboscis.alpha = 0
        addChild(proboscis)

        let antennaTop = SKShapeNode(path: linePath(from: CGPoint(x: 20, y: 3), to: CGPoint(x: 26, y: 8)))
        let antennaBottom = SKShapeNode(path: linePath(from: CGPoint(x: 20, y: -3), to: CGPoint(x: 26, y: -8)))
        for antenna in [antennaTop, antennaBottom] {
            antenna.strokeColor = NeuroFlyStyle.skCream.withAlphaComponent(0.72)
            antenna.lineWidth = 0.7
            addChild(antenna)
        }

        for side in [CGFloat(1), CGFloat(-1)] {
            for index in 0..<3 {
                let leg = SKShapeNode()
                leg.strokeColor = NeuroFlyStyle.skCream.withAlphaComponent(0.80)
                leg.lineWidth = 1
                leg.path = legPath(side: side, index: index, phase: 0)
                legs.append(leg)
                addChild(leg)
            }
        }

        identityLabel.fontSize = 10
        identityLabel.horizontalAlignmentMode = .center
        identityLabel.verticalAlignmentMode = .center
        identityLabel.position = CGPoint(x: 0, y: -41)
        identityLabel.isHidden = true
        addChild(identityLabel)
    }

    func apply(_ state: FlyState, elapsed: Double, phaseOffset: Double = 0,
               accent: SKColor = NeuroFlyStyle.skMint, selected: Bool = false,
               ordinal: Int = 1, showIdentity: Bool = false) {
        position = CGPoint(x: state.position.x, y: state.position.y)
        zRotation = state.heading

        let accentColor = accent.withAlphaComponent(1)
        selectionRing.isHidden = !selected
        selectionRing.strokeColor = accentColor.withAlphaComponent(0.92)
        aura.strokeColor = accentColor.withAlphaComponent(selected ? 0.52 : 0.25)
        aura.fillColor = accentColor.withAlphaComponent(selected ? 0.10 : 0.05)
        abdomen.strokeColor = accentColor.withAlphaComponent(selected ? 0.90 : 0.45)
        thorax.strokeColor = accentColor.withAlphaComponent(selected ? 0.95 : 0.52)
        identityLabel.text = "\(ordinal)"
        identityLabel.zRotation = -zRotation
        identityLabel.fontColor = accentColor.withAlphaComponent(selected ? 1 : 0.78)
        identityLabel.isHidden = !showIdentity

        let speed = max(0, min(state.speed / 240, 1))
        let active = state.activity == .flying || state.activity == .escaping
        let flapRate = active ? 20 + speed * 28 : 5 + speed * 8
        let flap = CGFloat(sin((elapsed + phaseOffset) * Double(flapRate)))
        // +X is the head. Wings extend toward -X from the thorax; keep their
        // visible sweep in the rear/lateral quadrants instead of over the head.
        let spread: CGFloat = active ? 0.55 + flap * 0.20 : -0.12
        leftWing.zRotation = -spread
        rightWing.zRotation = spread
        let projection: CGFloat = active ? 0.78 + abs(flap) * 0.22 : 0.72
        leftWing.yScale = projection
        rightWing.yScale = projection
        leftWing.alpha = active ? 0.90 : 0.58
        rightWing.alpha = active ? 0.90 : 0.58

        aura.alpha = state.activity == .escaping ? 0.86 : (active ? 0.62 : 0.28)
        aura.xScale = 1 + CGFloat(speed) * 0.16
        aura.yScale = 1 + CGFloat(speed) * 0.16
        proboscis.alpha = state.activity == .feeding ? 1 : 0

        for (index, leg) in legs.enumerated() {
            let side: CGFloat = index < 3 ? 1 : -1
            let legIndex = index % 3
            leg.path = legPath(side: side, index: legIndex, phase: flap * 0.16)
        }
        let bodyScale: CGFloat = state.activity == .escaping ? 1.10 : 1
        xScale = bodyScale
        yScale = bodyScale
    }

    private func wingPath(upper: Bool) -> CGPath {
        let sign: CGFloat = upper ? 1 : -1
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addCurve(to: CGPoint(x: -27, y: sign * 13),
                      control1: CGPoint(x: -12, y: sign * 14),
                      control2: CGPoint(x: -25, y: sign * 18))
        path.addCurve(to: CGPoint(x: -2, y: sign * 4),
                      control1: CGPoint(x: -25, y: sign * 5),
                      control2: CGPoint(x: -9, y: sign * 1))
        path.closeSubpath()
        return path
    }

    private func legPath(side: CGFloat, index: Int, phase: CGFloat) -> CGPath {
        let x = CGFloat(index) * 7 - 8
        let y = side * 4
        let direction = side * (index == 1 ? 1 : 0.72)
        let offset = phase * (index.isMultiple(of: 2) ? 1 : -1)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x - 4 + offset, y: y + direction * 7))
        path.addLine(to: CGPoint(x: x - 10, y: y + direction * (11 + CGFloat(index) * 1.5)))
        return path
    }

    private func linePath(from: CGPoint, to: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }
}

final class FoodNode: SKNode {
    private let fruit = SKShapeNode(circleOfRadius: 17)
    private let aura = SKShapeNode(circleOfRadius: 25)
    private let leaf = SKShapeNode()
    private let stem = SKShapeNode()
    private let glint = SKShapeNode(circleOfRadius: 3)

    override init() {
        super.init()
        setup()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }

    private func setup() {
        name = "food"
        aura.fillColor = NeuroFlyStyle.skOrange.withAlphaComponent(0.08)
        aura.strokeColor = NeuroFlyStyle.skOrange.withAlphaComponent(0.28)
        aura.lineWidth = 1
        addChild(aura)

        fruit.fillColor = NeuroFlyStyle.skOrange
        fruit.strokeColor = NeuroFlyStyle.skCream.withAlphaComponent(0.86)
        fruit.lineWidth = 1
        addChild(fruit)

        glint.position = CGPoint(x: -6, y: 6)
        glint.fillColor = NeuroFlyStyle.skCream.withAlphaComponent(0.80)
        glint.strokeColor = .clear
        glint.xScale = 0.55
        glint.yScale = 0.80
        addChild(glint)

        stem.path = linePath(from: CGPoint(x: 0, y: 14), to: CGPoint(x: 3, y: 24))
        stem.strokeColor = NeuroFlyStyle.skCream.withAlphaComponent(0.75)
        stem.lineWidth = 2
        addChild(stem)

        leaf.path = leafPath()
        leaf.fillColor = NeuroFlyStyle.skMint
        leaf.strokeColor = NeuroFlyStyle.skCream.withAlphaComponent(0.58)
        leaf.lineWidth = 0.7
        addChild(leaf)
    }

    func apply(_ food: FoodItem) {
        position = CGPoint(x: food.position.x, y: food.position.y)
        let foodColor = food.kind.neuroFlySKColor
        aura.fillColor = foodColor.withAlphaComponent(0.10)
        aura.strokeColor = foodColor.withAlphaComponent(0.42)
        fruit.fillColor = foodColor
        leaf.fillColor = food.kind == .berry ? NeuroFlyStyle.skCream : NeuroFlyStyle.skMint
        let remaining = CGFloat(max(0.42, min(1, food.remaining)))
        alpha = remaining
        aura.xScale = 0.86 + remaining * 0.14
        aura.yScale = 0.86 + remaining * 0.14
        fruit.xScale = 0.84 + remaining * 0.16
        fruit.yScale = 0.84 + remaining * 0.16
    }

    private func leafPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2, y: 20))
        path.addCurve(to: CGPoint(x: 14, y: 24), control1: CGPoint(x: 7, y: 29), control2: CGPoint(x: 13, y: 28))
        path.addCurve(to: CGPoint(x: 2, y: 20), control1: CGPoint(x: 11, y: 20), control2: CGPoint(x: 5, y: 18))
        path.closeSubpath()
        return path
    }

    private func linePath(from: CGPoint, to: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }
}

final class ShadowNode: SKNode {
    private let ring = SKShapeNode(circleOfRadius: 44)
    private let core = SKShapeNode(circleOfRadius: 30)

    override init() {
        super.init()
        ring.fillColor = .clear
        ring.strokeColor = NeuroFlyStyle.skCream.withAlphaComponent(0.52)
        ring.lineWidth = 1.5
        addChild(ring)
        core.fillColor = NeuroFlyStyle.skCanvas.withAlphaComponent(0.30)
        core.strokeColor = NeuroFlyStyle.skCream.withAlphaComponent(0.22)
        core.lineWidth = 1
        addChild(core)
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    func apply(position: Point2, strength: Double, elapsed: Double) {
        self.position = CGPoint(x: position.x, y: position.y)
        let s = CGFloat(max(0, min(1, strength)))
        let pulse = 1 + CGFloat(sin(elapsed * 5.5)) * 0.08
        ring.xScale = (0.74 + s * 0.38) * pulse
        ring.yScale = (0.74 + s * 0.38) * pulse
        core.xScale = 0.70 + s * 0.34
        core.yScale = 0.70 + s * 0.34
        ring.alpha = 0.25 + s * 0.75
        core.alpha = 0.22 + s * 0.56
    }
}

import AppKit
import SpriteKit
import NeuroFlyCore

@MainActor
final class ArenaViewController: NSViewController {
    let scene: ArenaScene

    var onAction: ((UserAction) -> Void)?
    var onShowBrain: (() -> Void)?
    var onShowDesktop: (() -> Void)?
    var onResize: ((CGSize) -> Void)?

    private let arenaView = ArenaSKView()
    private let activityLabel = NSTextField(labelWithString: "쉬는 중")
    private let activityDot = NSView()
    private let elapsedLabel = NSTextField(labelWithString: "00:00")
    private let hintLabel = NSTextField(labelWithString: ArenaTool.food.hint)
    private let explainerLabel = NSTextField(labelWithString: "FlyWire v783 연결 데이터 · 단순화된 몸체 · 계산된 신경 출력으로 움직입니다")
    private let pauseButton = NSButton(title: "일시정지", target: nil, action: nil)
    private var toolButtons: [ArenaTool: NSButton] = [:]
    private var currentTool: ArenaTool = .food
    private var didLayoutOnce = false

    init(scene: ArenaScene? = nil) {
        self.scene = scene ?? ArenaScene(size: CGSize(width: 1000, height: 650))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.scene = ArenaScene(size: CGSize(width: 1000, height: 650))
        super.init(coder: coder)
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        view.layer?.backgroundColor = NeuroFlyStyle.canvas.cgColor

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 14, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        root.addArrangedSubview(makeToolbar())
        root.addArrangedSubview(makeArenaCard())
        root.addArrangedSubview(makeFooter())

        scene.onArenaClick = { [weak self] point in
            self?.handleArenaClick(point)
        }
        scene.onEscape = { [weak self] in
            self?.cancelTool()
        }
        arenaView.onEscape = { [weak self] in
            self?.cancelTool()
        }
        arenaView.presentScene(scene)
        arenaView.preferredFramesPerSecond = 60
        arenaView.ignoresSiblingOrder = true
        arenaView.wantsLayer = true
        arenaView.layer?.cornerRadius = 18
        arenaView.layer?.masksToBounds = true
        arenaView.window?.acceptsMouseMovedEvents = true
        selectTool(.food)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(arenaView)
    }

    func render(_ snapshot: WorldSnapshot) {
        scene.apply(snapshot)
        activityLabel.stringValue = snapshot.fly.activity.label
        elapsedLabel.stringValue = elapsedText(snapshot.elapsed)
        hintLabel.stringValue = snapshot.isPaused ? "일시정지됨 · 다시 시작하려면 버튼을 누르세요" : currentTool.hint
        pauseButton.title = snapshot.isPaused ? "다시 시작" : "일시정지"
        activityDot.layer?.backgroundColor = activityColor(for: snapshot).cgColor
        explainerLabel.stringValue = snapshot.error.map { "오류 · \($0)" } ?? "FlyWire v783 연결 데이터 · 단순화된 몸체 · 계산된 신경 출력으로 움직입니다"
        explainerLabel.textColor = snapshot.error == nil ? NeuroFlyStyle.dimInk : NeuroFlyStyle.coral
    }

    private func makeToolbar() -> NSView {
        let card = CardView(fill: NeuroFlyStyle.canvasRaised, border: NeuroFlyStyle.canvasLine, radius: 14)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 66).isActive = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            row.topAnchor.constraint(equalTo: card.topAnchor),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        let brand = NSStackView()
        brand.orientation = .vertical
        brand.alignment = .leading
        brand.spacing = 2
        let title = NSTextField(labelWithString: "NEUROFLY")
        title.font = .systemFont(ofSize: 15, weight: .bold)
        title.textColor = NeuroFlyStyle.cream
        let subtitle = NSTextField(labelWithString: "신경 연결 실험실")
        subtitle.font = .systemFont(ofSize: 10, weight: .medium)
        subtitle.textColor = NeuroFlyStyle.mutedInk
        brand.addArrangedSubview(title)
        brand.addArrangedSubview(subtitle)
        brand.setContentHuggingPriority(.required, for: .horizontal)
        brand.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(brand)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NeuroFlyStyle.canvasLine.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 34).isActive = true
        row.addArrangedSubview(divider)

        let toolGroup = NSStackView()
        toolGroup.orientation = .horizontal
        toolGroup.spacing = 4
        for tool in ArenaTool.allCases {
            let button = makeButton(tool.title, action: #selector(toolButtonPressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            button.setButtonType(.toggle)
            button.widthAnchor.constraint(equalToConstant: tool == .food || tool == .touch ? 78 : 64).isActive = true
            toolButtons[tool] = button
            toolGroup.addArrangedSubview(button)
        }
        row.addArrangedSubview(toolGroup)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        row.addArrangedSubview(makeSmallButton("비우기", action: #selector(clearButtonPressed)))
        pauseButton.target = self
        pauseButton.action = #selector(pauseButtonPressed)
        styleButton(pauseButton, accented: true)
        row.addArrangedSubview(pauseButton)
        row.addArrangedSubview(makeSmallButton("다시 시작", action: #selector(resetButtonPressed)))
        row.addArrangedSubview(makeSmallButton("데스크톱", action: #selector(desktopButtonPressed)))
        row.addArrangedSubview(makeSmallButton("뇌 보기", action: #selector(brainButtonPressed)))
        return card
    }

    private func makeArenaCard() -> NSView {
        let card = CardView(fill: NeuroFlyStyle.canvas, border: NeuroFlyStyle.canvasLine, radius: 18)
        card.translatesAutoresizingMaskIntoConstraints = false

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(statusRow)
        NSLayoutConstraint.activate([
            statusRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            statusRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            statusRow.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            statusRow.heightAnchor.constraint(equalToConstant: 25)
        ])

        activityDot.wantsLayer = true
        activityDot.layer?.cornerRadius = 4
        activityDot.translatesAutoresizingMaskIntoConstraints = false
        statusRow.addArrangedSubview(activityDot)
        activityDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        activityDot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        activityLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        activityLabel.textColor = NeuroFlyStyle.ink
        statusRow.addArrangedSubview(activityLabel)

        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusRow.addArrangedSubview(statusSpacer)
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = NeuroFlyStyle.mutedInk
        statusRow.addArrangedSubview(elapsedLabel)

        arenaView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(arenaView)
        NSLayoutConstraint.activate([
            arenaView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            arenaView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            arenaView.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 5),
            arenaView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            arenaView.heightAnchor.constraint(greaterThanOrEqualToConstant: 380)
        ])
        return card
    }

    private func makeFooter() -> NSView {
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.heightAnchor.constraint(equalToConstant: 24).isActive = true

        hintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hintLabel.textColor = NeuroFlyStyle.cream
        footer.addArrangedSubview(hintLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer)
        explainerLabel.font = .systemFont(ofSize: 10, weight: .regular)
        explainerLabel.alignment = .right
        explainerLabel.lineBreakMode = .byTruncatingTail
        explainerLabel.textColor = NeuroFlyStyle.dimInk
        footer.addArrangedSubview(explainerLabel)
        return footer
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.bezelStyle = .texturedRounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        styleButton(button, accented: false)
        return button
    }

    private func makeSmallButton(_ title: String, action: Selector) -> NSButton {
        let button = makeButton(title, action: action)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: title.count > 3 ? 58 : 52).isActive = true
        return button
    }

    private func styleButton(_ button: NSButton, accented: Bool) {
        button.appearance = NSAppearance(named: .darkAqua)
        button.contentTintColor = accented ? NeuroFlyStyle.mint : NeuroFlyStyle.ink
        button.bezelColor = accented ? NeuroFlyStyle.mintSoft : NeuroFlyStyle.canvasRaised
    }

    private func handleArenaClick(_ point: Point2) {
        switch currentTool {
        case .food:
            onAction?(.placeFood(point))
        case .shadow:
            onAction?(.castShadow(point))
        case .touch:
            onAction?(.touchFly)
        }
        arenaView.window?.makeFirstResponder(arenaView)
    }

    private func selectTool(_ tool: ArenaTool) {
        currentTool = tool
        scene.setTool(tool)
        hintLabel.stringValue = tool.hint
        for (candidate, button) in toolButtons {
            button.state = candidate == tool ? .on : .off
            button.bezelColor = candidate == tool ? NeuroFlyStyle.creamSoft : NeuroFlyStyle.canvasRaised
            button.contentTintColor = candidate == tool ? NeuroFlyStyle.cream : NeuroFlyStyle.ink
        }
    }

    private func cancelTool() {
        selectTool(.food)
    }

    @objc private func toolButtonPressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let tool = ArenaTool(rawValue: raw) else { return }
        selectTool(tool)
    }

    @objc private func clearButtonPressed() { onAction?(.clearFood) }
    @objc private func pauseButtonPressed() { onAction?(.togglePause) }
    @objc private func resetButtonPressed() { onAction?(.reset) }
    @objc private func desktopButtonPressed() { onShowDesktop?() }
    @objc private func brainButtonPressed() { onShowBrain?() }

    private func elapsedText(_ value: Double) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func activityColor(for snapshot: WorldSnapshot) -> NSColor {
        switch snapshot.fly.activity {
        case .resting: return NeuroFlyStyle.mutedInk
        case .flying: return NeuroFlyStyle.mint
        case .feeding: return NeuroFlyStyle.orange
        case .escaping: return NeuroFlyStyle.coral
        case .grooming: return NeuroFlyStyle.cream
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard arenaView.bounds.width > 0, arenaView.bounds.height > 0 else { return }
        let size = arenaView.bounds.size
        let oldSize = scene.size
        let changed = abs(size.width - oldSize.width) > 0.1 || abs(size.height - oldSize.height) > 0.1
        scene.size = size
        if !didLayoutOnce || changed {
            didLayoutOnce = true
            onResize?(size)
        }
    }
}

final class CardView: NSView {
    private let fill: NSColor
    private let border: NSColor
    private let radius: CGFloat

    init(fill: NSColor, border: NSColor, radius: CGFloat) {
        self.fill = fill
        self.border = border
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.borderWidth = 1
        layer?.borderColor = border.cgColor
        layer?.backgroundColor = fill.cgColor
    }

    required init?(coder: NSCoder) {
        self.fill = NeuroFlyStyle.canvas
        self.border = NeuroFlyStyle.canvasLine
        self.radius = 12
        super.init(coder: coder)
    }
}

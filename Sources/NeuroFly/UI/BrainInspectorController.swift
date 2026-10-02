import AppKit
import NeuroFlyCore

@MainActor
final class BrainInspectorController: NSWindowController, NSWindowDelegate {
    var onAction: ((UserAction) -> Void)?

    private let statusLabel = NSTextField(labelWithString: "신경망을 불러오는 중…")
    private let detailLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "뉴런 — · 연결 —")
    private let realtimeLabel = NSTextField(labelWithString: "실시간 배율 —")
    private let bodySpeedLabel = NSTextField(labelWithString: "—")
    private let bodyTurnLabel = NSTextField(labelWithString: "—")
    private let bodyActivityLabel = NSTextField(labelWithString: "—")
    private let sensorySwitch = NSSwitch()
    private var sensoryRows: [(RateMeterView, NSTextField)] = []
    private var relayRows: [(RateMeterView, NSTextField)] = []
    private var neuralRows: [(RateMeterView, NSTextField)] = []
    private var didBuild = false

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 382, height: 640),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "NeuroFly · 뇌 보기"
        panel.minSize = NSSize(width: 382, height: 400)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        buildView()
    }

    required init?(coder: NSCoder) {
        fatalError("BrainInspectorController does not support storyboards")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func update(_ snapshot: WorldSnapshot) {
        guard didBuild else { return }
        statusLabel.stringValue = snapshot.error == nil ? (snapshot.isReady ? "실시간 신경망" : "신경망 초기화 중") : "신경망 오류"
        statusLabel.textColor = snapshot.error == nil ? NeuroFlyStyle.cream : NeuroFlyStyle.coral
        detailLabel.stringValue = snapshot.error ?? snapshot.status
        detailLabel.textColor = snapshot.error == nil ? NeuroFlyStyle.mutedInk : NeuroFlyStyle.coral
        countsLabel.stringValue = "뉴런 \(String.neuroFlyCount(snapshot.neuronCount))  ·  연결 \(String.neuroFlyCount(snapshot.edgeCount))"
        realtimeLabel.stringValue = snapshot.realtimeFactor > 0 ? String(format: "실시간 배율 %.2fx", snapshot.realtimeFactor) : "실시간 배율 측정 중"
        sensorySwitch.state = snapshot.sensoryEnabled ? .on : .off

        let sensoryValues: [(Float, String)] = [
            (snapshot.sensory.odorLeft, "냄새 · 몸 왼쪽"),
            (snapshot.sensory.odorRight, "냄새 · 몸 오른쪽"),
            (snapshot.sensory.taste, "단맛"),
            (snapshot.sensory.loomingLeft, "그림자 · 몸 왼쪽"),
            (snapshot.sensory.loomingRight, "그림자 · 몸 오른쪽"),
            (snapshot.sensory.touch, "접촉")
        ]
        for (index, item) in sensoryValues.enumerated() where index < sensoryRows.count {
            sensoryRows[index].0.value = CGFloat(max(0, min(1, item.0)))
            sensoryRows[index].1.stringValue = String(format: "%.2f", item.0)
        }

        let relayValues: [Float] = [snapshot.neural.odorRelayLeftHz, snapshot.neural.odorRelayRightHz]
        for (index, value) in relayValues.enumerated() where index < relayRows.count {
            relayRows[index].0.value = CGFloat(max(0, min(1, value / 500)))
            relayRows[index].1.stringValue = String.neuroFlyRate(value)
        }

        let neuralValues: [(Float, String)] = [
            (snapshot.neural.turnLeftHz, "회전 · 몸 왼쪽"),
            (snapshot.neural.turnRightHz, "회전 · 몸 오른쪽"),
            (snapshot.neural.forwardHz, "전진"),
            (snapshot.neural.escapeHz, "회피"),
            (snapshot.neural.feedingHz, "섭식"),
            (snapshot.neural.groomingHz, "그루밍"),
            (snapshot.neural.populationHz, "전체 뉴런")
        ]
        for (index, item) in neuralValues.enumerated() where index < neuralRows.count {
            let maxRate: Float = item.0 > 100 ? max(item.0, 180) : 100
            neuralRows[index].0.value = CGFloat(max(0, min(1, item.0 / maxRate)))
            neuralRows[index].1.stringValue = String.neuroFlyRate(item.0)
        }

        bodySpeedLabel.stringValue = String(format: "%.1f px/s", max(0, snapshot.fly.speed))
        bodyTurnLabel.stringValue = bodyTurnDescription(snapshot.motor.turnRate)
        bodyActivityLabel.stringValue = snapshot.motor.activity.label
    }

    private func buildView() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NeuroFlyStyle.canvas.cgColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let document = NSView()
        document.wantsLayer = true
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualToConstant: 650)
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 18, bottom: 20, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor)
        ])

        let heading = NSTextField(labelWithString: "신경 상태")
        heading.font = .systemFont(ofSize: 21, weight: .bold)
        heading.textColor = NeuroFlyStyle.cream
        stack.addArrangedSubview(heading)

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 10, weight: .regular)
        detailLabel.usesSingleLineMode = false
        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.preferredMaxLayoutWidth = 310
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusCard = CardView(fill: NeuroFlyStyle.canvasRaised, border: NeuroFlyStyle.canvasLine, radius: 12)
        let statusStack = NSStackView(views: [statusLabel, detailLabel])
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 4
        statusStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusCard.addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor),
            statusStack.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor),
            statusStack.topAnchor.constraint(equalTo: statusCard.topAnchor),
            statusStack.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor)
        ])
        stack.addArrangedSubview(statusCard)

        let metaRow = NSStackView()
        metaRow.orientation = .horizontal
        metaRow.spacing = 8
        metaRow.alignment = .centerY
        countsLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        countsLabel.textColor = NeuroFlyStyle.mutedInk
        metaRow.addArrangedSubview(countsLabel)
        let metaSpacer = NSView()
        metaSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metaRow.addArrangedSubview(metaSpacer)
        realtimeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        realtimeLabel.textColor = NeuroFlyStyle.mint
        metaRow.addArrangedSubview(realtimeLabel)
        stack.addArrangedSubview(metaRow)

        stack.addArrangedSubview(sectionTitle("감각 입력", detail: "더듬이에서 감지한 냄새 농도 · 뉴런 발화율과 다름 · 좌우는 화면이 아닌 펫 몸 기준"))
        let sensory = ["냄새 · 몸 왼쪽", "냄새 · 몸 오른쪽", "단맛", "그림자 · 몸 왼쪽", "그림자 · 몸 오른쪽", "접촉"]
        for title in sensory {
            let meter = RateMeterView(tint: NeuroFlyStyle.orange)
            let value = NSTextField(labelWithString: "0.00")
            stack.addArrangedSubview(makeMeterRow(title: title, meter: meter, value: value))
            sensoryRows.append((meter, value))
        }

        let switchRow = NSStackView()
        switchRow.orientation = .horizontal
        switchRow.alignment = .centerY
        switchRow.spacing = 8
        let switchLabel = NSTextField(labelWithString: "감각 입력 연결")
        switchLabel.font = .systemFont(ofSize: 11, weight: .medium)
        switchLabel.textColor = NeuroFlyStyle.ink
        switchRow.addArrangedSubview(switchLabel)
        let switchSpacer = NSView()
        switchSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        switchRow.addArrangedSubview(switchSpacer)
        sensorySwitch.controlSize = .small
        sensorySwitch.target = self
        sensorySwitch.action = #selector(sensorySwitchChanged(_:))
        switchRow.addArrangedSubview(sensorySwitch)
        stack.addArrangedSubview(switchRow)

        stack.addArrangedSubview(sectionTitle("후각 중계 · DM1_lPN", detail: "DM1_lPN 뉴런의 계산된 발화율 · 화면 속 선회에 사용하는 신호 · 좌우는 펫 몸 기준"))
        let relays = ["DM1_lPN · 몸 왼쪽", "DM1_lPN · 몸 오른쪽"]
        for title in relays {
            let meter = RateMeterView(tint: NeuroFlyStyle.cream)
            let value = NSTextField(labelWithString: "0.00 Hz")
            stack.addArrangedSubview(makeMeterRow(title: title, meter: meter, value: value))
            relayRows.append((meter, value))
        }

        stack.addArrangedSubview(sectionTitle("운동 뉴런", detail: "운동 관련 뉴런 집단의 원시 발화율 · 몸체 반응과 별도"))
        let neural = ["회전 · 몸 왼쪽", "회전 · 몸 오른쪽", "전진", "회피", "섭식", "그루밍", "전체 뉴런"]
        for title in neural {
            let meter = RateMeterView(tint: NeuroFlyStyle.mint)
            let value = NSTextField(labelWithString: "0.00 Hz")
            stack.addArrangedSubview(makeMeterRow(title: title, meter: meter, value: value))
            neuralRows.append((meter, value))
        }

        stack.addArrangedSubview(sectionTitle("몸체 반응", detail: "실제 이동 속도 · 신경 출력으로 정한 선회 방향과 활동"))
        let bodyCard = CardView(fill: NeuroFlyStyle.canvasRaised, border: NeuroFlyStyle.canvasLine, radius: 10)
        let bodyStack = NSStackView(views: [
            makeBodyValueRow(title: "속도", value: bodySpeedLabel),
            makeBodyValueRow(title: "선회", value: bodyTurnLabel),
            makeBodyValueRow(title: "활동", value: bodyActivityLabel)
        ])
        bodyStack.orientation = .vertical
        bodyStack.alignment = .width
        bodyStack.spacing = 5
        bodyStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyCard.addSubview(bodyStack)
        NSLayoutConstraint.activate([
            bodyStack.leadingAnchor.constraint(equalTo: bodyCard.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: bodyCard.trailingAnchor),
            bodyStack.topAnchor.constraint(equalTo: bodyCard.topAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: bodyCard.bottomAnchor)
        ])
        stack.addArrangedSubview(bodyCard)

        let note = NSTextField(wrappingLabelWithString: "이 패널은 매 프레임 계산된 값을 보여줍니다. 감각 입력을 끄면 같은 자극에서 운동 출력이 어떻게 달라지는지 비교할 수 있습니다.")
        note.font = .systemFont(ofSize: 10, weight: .regular)
        note.textColor = NeuroFlyStyle.dimInk
        stack.addArrangedSubview(note)

        didBuild = true
    }

    private func sectionTitle(_ title: String, detail: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = NeuroFlyStyle.cream
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = NeuroFlyStyle.dimInk
        detailLabel.preferredMaxLayoutWidth = 330
        detailLabel.maximumNumberOfLines = 0
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(detailLabel)
        return stack
    }

    private func makeMeterRow(title: String, meter: RateMeterView, value: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .regular)
        label.textColor = NeuroFlyStyle.mutedInk
        label.widthAnchor.constraint(equalToConstant: 104).isActive = true
        row.addArrangedSubview(label)
        meter.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(meter)
        meter.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        value.textColor = NeuroFlyStyle.ink
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 55).isActive = true
        row.addArrangedSubview(value)
        return row
    }

    private func makeBodyValueRow(title: String, value: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 10, weight: .regular)
        titleLabel.textColor = NeuroFlyStyle.mutedInk
        titleLabel.widthAnchor.constraint(equalToConstant: 104).isActive = true
        row.addArrangedSubview(titleLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        value.textColor = NeuroFlyStyle.ink
        value.alignment = .right
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(value)
        return row
    }

    private func bodyTurnDescription(_ turnRate: Double) -> String {
        guard turnRate.isFinite else { return "—" }
        let degreesPerSecond = turnRate * 180 / Double.pi
        let magnitude = abs(degreesPerSecond)
        guard magnitude >= 0.5 else { return "직진 · 0.0°/s" }
        let direction = degreesPerSecond > 0 ? "왼쪽" : "오른쪽"
        return String(format: "%@ · %.1f°/s", direction, magnitude)
    }

    @objc private func sensorySwitchChanged(_ sender: NSSwitch) {
        onAction?(.toggleSensory)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

final class RateMeterView: NSView {
    var value: CGFloat = 0 {
        didSet {
            value = max(0, min(1, value))
            needsDisplay = true
        }
    }
    private let tint: NSColor

    init(tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 8).isActive = true
    }

    required init?(coder: NSCoder) {
        self.tint = NeuroFlyStyle.mint
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = NSRect(x: 0, y: 0, width: bounds.width, height: 8)
        let background = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        NeuroFlyStyle.canvasLine.setFill()
        background.fill()
        let fillRect = NSRect(x: 0, y: 0, width: bounds.width * value, height: bounds.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: 4, yRadius: 4)
        tint.setFill()
        fill.fill()
    }
}

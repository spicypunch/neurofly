import AppKit
import NeuroFlyCore

private final class BrainInspectorDocumentView: NSView {
    override var isFlipped: Bool { true }
}

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
    private let hungerMeter = RateMeterView(tint: NeuroFlyStyle.orange)
    private let hungerValueLabel = NSTextField(labelWithString: "—")
    private let foodReactionLabel = NSTextField(labelWithString: "—")
    private let consumedFoodLabel = NSTextField(labelWithString: "—")
    private let individualPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let learningSwitch = NSSwitch()
    private let clearMemoryButton = NSButton(title: "기억 지우기", target: nil, action: nil)
    private let bananaMemoryLabel = NSTextField(labelWithString: "—")
    private let berryMemoryLabel = NSTextField(labelWithString: "—")
    private let memorySummaryLabel = NSTextField(labelWithString: "—")
    private let sensorySwitch = NSSwitch()
    private var sensoryRows: [(RateMeterView, NSTextField)] = []
    private var relayRows: [(RateMeterView, NSTextField)] = []
    private var neuralRows: [(RateMeterView, NSTextField)] = []
    private var individualIDs: [UUID] = []
    private var brainModels: [BrainModel] = []
    private var isUpdatingControls = false
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
        if snapshot.error != nil {
            statusLabel.stringValue = "신경망 오류"
        } else if snapshot.isPaused {
            statusLabel.stringValue = "일시정지"
        } else {
            statusLabel.stringValue = snapshot.isReady ? "실시간 신경망" : "신경망 초기화 중"
        }
        statusLabel.textColor = snapshot.error == nil ? NeuroFlyStyle.cream : NeuroFlyStyle.coral
        let individuals = snapshot.individuals
        let selectedOrdinal = individuals.first(where: { $0.id == snapshot.selectedIndividualID })?.ordinal ?? 0
        let selectedCount = max(1, individuals.count)
        let selectionDetail = "\(snapshot.brainModel.displayName) · 선택 개체 #\(selectedOrdinal + 1) · 총 \(selectedCount)개"
        detailLabel.stringValue = snapshot.error ?? "\(selectionDetail) · \(snapshot.status)"
        detailLabel.textColor = snapshot.error == nil ? NeuroFlyStyle.mutedInk : NeuroFlyStyle.coral
        countsLabel.stringValue = "뉴런 \(String.neuroFlyCount(snapshot.neuronCount))  ·  연결 \(String.neuroFlyCount(snapshot.edgeCount))"
        realtimeLabel.stringValue = snapshot.realtimeFactor > 0 ? String(format: "실시간 배율 %.2fx", snapshot.realtimeFactor) : "실시간 배율 측정 중"
        sensorySwitch.state = snapshot.sensoryEnabled ? .on : .off
        updatePopulationControls(snapshot)

        let memoryStats = snapshot.memory.stats
        bananaMemoryLabel.stringValue = String(format: "값 %.2f · gain %.2f", memoryStats.bananaValue, memoryStats.bananaGain)
        berryMemoryLabel.stringValue = String(format: "값 %.2f · gain %.2f", memoryStats.berryValue, memoryStats.berryGain)
        memorySummaryLabel.stringValue = String(format: "학습 사건 %d회 · 실제 섭취 %.2f · 위협 연합 %d회",
                                                 memoryStats.learnedFood,
                                                 memoryStats.rewardedIntake,
                                                 memoryStats.threatAssociations)

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

        let hunger = snapshot.body.hunger.isFinite ? max(0, min(1, snapshot.body.hunger)) : 0
        let consumedFood = snapshot.body.consumedFood.isFinite
            ? max(0, snapshot.body.consumedFood)
            : 0
        hungerMeter.value = CGFloat(hunger)
        hungerValueLabel.stringValue = String(format: "%.0f%%", hunger * 100)
        foodReactionLabel.stringValue = !snapshot.sensoryEnabled ? "감각 연결 꺼짐" :
            (snapshot.body.isFoodMotivated ? "먹이 찾기" : "포만 · 잠시 멈춤")
        foodReactionLabel.textColor = snapshot.body.isFoodMotivated ? NeuroFlyStyle.orange : NeuroFlyStyle.ink
        consumedFoodLabel.stringValue = String(format: "%.2f개", consumedFood)
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

        let document = BrainInspectorDocumentView()
        document.wantsLayer = true
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualToConstant: 650)
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 18, bottom: 20, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        let heading = NSTextField(labelWithString: "신경 상태")
        heading.font = .systemFont(ofSize: 21, weight: .bold)
        heading.textColor = NeuroFlyStyle.cream
        heading.alignment = .left
        stack.addArrangedSubview(heading)

        stack.addArrangedSubview(sectionTitle("실험 개체", detail: "선택한 개체의 신호와 몸체 반응을 표시합니다 · 최대 4개"))
        stack.addArrangedSubview(makePopulationCard())

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 10, weight: .regular)
        detailLabel.usesSingleLineMode = false
        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.preferredMaxLayoutWidth = 310
        statusLabel.alignment = .left
        detailLabel.alignment = .left
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        statusLabel.widthAnchor.constraint(equalTo: statusStack.widthAnchor, constant: -24).isActive = true
        detailLabel.widthAnchor.constraint(equalTo: statusStack.widthAnchor, constant: -24).isActive = true
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

        stack.addArrangedSubview(sectionTitle("몸 상태", detail: "시간이 흐르면 늘고, 먹은 양만큼 줄어드는 가상 허기"))
        let bodyStatusCard = CardView(fill: NeuroFlyStyle.canvasRaised, border: NeuroFlyStyle.canvasLine, radius: 10)
        let bodyStatusStack = NSStackView(views: [
            makeMeterRow(title: "허기", meter: hungerMeter, value: hungerValueLabel),
            makeBodyValueRow(title: "먹이 반응", value: foodReactionLabel),
            makeBodyValueRow(title: "누적 섭취", value: consumedFoodLabel)
        ])
        bodyStatusStack.orientation = .vertical
        bodyStatusStack.alignment = .width
        bodyStatusStack.spacing = 5
        bodyStatusStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        bodyStatusStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStatusCard.addSubview(bodyStatusStack)
        NSLayoutConstraint.activate([
            bodyStatusStack.leadingAnchor.constraint(equalTo: bodyStatusCard.leadingAnchor),
            bodyStatusStack.trailingAnchor.constraint(equalTo: bodyStatusCard.trailingAnchor),
            bodyStatusStack.topAnchor.constraint(equalTo: bodyStatusCard.topAnchor),
            bodyStatusStack.bottomAnchor.constraint(equalTo: bodyStatusCard.bottomAnchor)
        ])
        stack.addArrangedSubview(bodyStatusCard)

        let bodyStatusNote = NSTextField(wrappingLabelWithString: "배부르면 먹이 반응을 잠시 쉽니다. 냄새 농도는 계속 표시되며, 그림자와 접촉에는 반응합니다.")
        bodyStatusNote.font = .systemFont(ofSize: 10, weight: .regular)
        bodyStatusNote.textColor = NeuroFlyStyle.dimInk
        bodyStatusNote.alignment = .left
        bodyStatusNote.preferredMaxLayoutWidth = 310
        bodyStatusNote.usesSingleLineMode = false
        bodyStatusNote.maximumNumberOfLines = 0
        bodyStatusNote.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(bodyStatusNote)

        stack.addArrangedSubview(sectionTitle("가상 먹이 기억", detail: "연결 지도의 시냅스가 바뀌는 기능이 아닙니다 · 냄새 단서와 실제 섭취를 이용한 앱 수준 연합값"))
        stack.addArrangedSubview(makeMemoryCard())

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
        note.alignment = .left
        note.preferredMaxLayoutWidth = 310
        note.usesSingleLineMode = false
        note.maximumNumberOfLines = 0
        note.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(note)

        for arrangedView in stack.arrangedSubviews {
            arrangedView.translatesAutoresizingMaskIntoConstraints = false
            arrangedView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }

        didBuild = true
    }

    private func makePopulationCard() -> NSView {
        let card = CardView(fill: NeuroFlyStyle.canvasRaised, border: NeuroFlyStyle.canvasLine, radius: 10)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        let selectionRow = NSStackView()
        selectionRow.orientation = .horizontal
        selectionRow.alignment = .centerY
        selectionRow.spacing = 7
        let selectionLabel = NSTextField(labelWithString: "개체")
        styleControlLabel(selectionLabel)
        selectionLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        selectionRow.addArrangedSubview(selectionLabel)
        stylePopup(individualPopup)
        individualPopup.target = self
        individualPopup.action = #selector(individualPopupChanged(_:))
        individualPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
        selectionRow.addArrangedSubview(individualPopup)

        let modelLabel = NSTextField(labelWithString: "모델")
        styleControlLabel(modelLabel)
        modelLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        selectionRow.addArrangedSubview(modelLabel)
        stylePopup(modelPopup)
        modelPopup.target = self
        modelPopup.action = #selector(modelPopupChanged(_:))
        modelPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 118).isActive = true
        selectionRow.addArrangedSubview(modelPopup)
        stack.addArrangedSubview(selectionRow)

        let learningRow = NSStackView()
        learningRow.orientation = .horizontal
        learningRow.alignment = .centerY
        learningRow.spacing = 7
        let learningLabel = NSTextField(labelWithString: "먹이 기억 학습")
        styleControlLabel(learningLabel)
        learningRow.addArrangedSubview(learningLabel)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        learningRow.addArrangedSubview(spacer)
        learningSwitch.controlSize = .small
        learningSwitch.target = self
        learningSwitch.action = #selector(learningSwitchChanged(_:))
        learningRow.addArrangedSubview(learningSwitch)
        clearMemoryButton.target = self
        clearMemoryButton.action = #selector(clearMemoryPressed)
        clearMemoryButton.bezelStyle = .texturedRounded
        clearMemoryButton.controlSize = .small
        clearMemoryButton.font = .systemFont(ofSize: 10, weight: .medium)
        clearMemoryButton.contentTintColor = NeuroFlyStyle.ink
        clearMemoryButton.appearance = NSAppearance(named: .darkAqua)
        learningRow.addArrangedSubview(clearMemoryButton)
        stack.addArrangedSubview(learningRow)
        return card
    }

    private func makeMemoryCard() -> NSView {
        let card = CardView(fill: NeuroFlyStyle.canvasRaised, border: NeuroFlyStyle.canvasLine, radius: 10)
        let stack = NSStackView(views: [
            makeBodyValueRow(title: "바나나", value: bananaMemoryLabel),
            makeBodyValueRow(title: "베리", value: berryMemoryLabel),
            makeBodyValueRow(title: "요약", value: memorySummaryLabel)
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        return card
    }

    private func stylePopup(_ popup: NSPopUpButton) {
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 10, weight: .medium)
        popup.bezelStyle = .texturedRounded
        popup.appearance = NSAppearance(named: .darkAqua)
        popup.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func styleControlLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = NeuroFlyStyle.mutedInk
    }

    private func updatePopulationControls(_ snapshot: WorldSnapshot) {
        let individuals = snapshot.individuals
        let ids = individuals.map(\.id)
        let models = snapshot.availableBrainModels
        isUpdatingControls = true
        if ids != individualIDs {
            individualIDs = ids
            individualPopup.removeAllItems()
            if individuals.isEmpty {
                individualPopup.addItem(withTitle: "개체 1")
            } else {
                for individual in individuals {
                    individualPopup.addItem(withTitle: "개체 \(individual.ordinal + 1)")
                }
            }
        }
        if let selectedID = snapshot.selectedIndividualID,
           let selectedIndex = individualIDs.firstIndex(of: selectedID) {
            individualPopup.selectItem(at: selectedIndex)
        } else {
            individualPopup.selectItem(at: 0)
        }
        if models != brainModels {
            brainModels = models
            modelPopup.removeAllItems()
            for model in models {
                modelPopup.addItem(withTitle: model.displayName)
            }
        }
        if let modelIndex = brainModels.firstIndex(of: snapshot.brainModel) {
            modelPopup.selectItem(at: modelIndex)
        }
        let isPreparing = !snapshot.isReady && snapshot.error == nil
        let individualActionsEnabled = !isPreparing && !individuals.isEmpty
        learningSwitch.state = snapshot.memory.learningEnabled ? .on : .off
        individualPopup.isEnabled = individualActionsEnabled && individuals.count > 1
        learningSwitch.isEnabled = individualActionsEnabled
        clearMemoryButton.isEnabled = individualActionsEnabled
        // A failed initialization can still recover by selecting another model,
        // while the initial preparation window keeps model changes queued out.
        modelPopup.isEnabled = brainModels.count > 1 && (snapshot.isReady || snapshot.error != nil)
        isUpdatingControls = false
    }

    private func sectionTitle(_ title: String, detail: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = NeuroFlyStyle.cream
        titleLabel.alignment = .left
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = NeuroFlyStyle.dimInk
        detailLabel.alignment = .left
        detailLabel.preferredMaxLayoutWidth = 310
        detailLabel.maximumNumberOfLines = 0
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(detailLabel)
        titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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

    @objc private func individualPopupChanged(_ sender: NSPopUpButton) {
        guard !isUpdatingControls,
              sender.isEnabled,
              sender.indexOfSelectedItem >= 0,
              sender.indexOfSelectedItem < individualIDs.count else { return }
        onAction?(.selectIndividual(individualIDs[sender.indexOfSelectedItem]))
    }

    @objc private func modelPopupChanged(_ sender: NSPopUpButton) {
        guard !isUpdatingControls,
              sender.isEnabled,
              sender.indexOfSelectedItem >= 0,
              sender.indexOfSelectedItem < brainModels.count else { return }
        onAction?(.switchBrainModel(brainModels[sender.indexOfSelectedItem]))
    }

    @objc private func learningSwitchChanged(_ sender: NSSwitch) {
        guard !isUpdatingControls, sender.isEnabled else { return }
        onAction?(.toggleLearning)
    }

    @objc private func clearMemoryPressed() {
        guard clearMemoryButton.isEnabled else { return }
        onAction?(.clearMemory)
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

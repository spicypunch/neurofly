import AppKit
import NeuroFlyCore

/// AppKit entry point for the experiment window and the optional click-through pet.
/// The controller only forwards user actions to SimulationSession and renders its snapshots.
@MainActor
final class DesktopAppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let session: SimulationSession
    private var arenaWindow: NSWindow?
    private var arenaController: ArenaViewController?
    private var brainInspector: BrainInspectorController?
    private var desktopMode: DesktopModeController?
    private var statusItem: NSStatusItem?
    private var petVisibilityItem: NSMenuItem?
    private var pauseItem: NSMenuItem?
    private var addIndividualItem: NSMenuItem?
    private var removeIndividualItem: NSMenuItem?
    private var learningItem: NSMenuItem?
    private var clearMemoryItem: NSMenuItem?
    private var selectIndividualMenu: NSMenu?
    private var selectIndividualMenuItem: NSMenuItem?
    private var brainModelMenu: NSMenu?
    private var brainModelMenuItem: NSMenuItem?
    private var menuIndividualIDs: [UUID] = []
    private var menuIndividualOrdinals: [Int] = []
    private var menuBrainModels: [BrainModel] = []
    private var latestSnapshot = WorldSnapshot()
    private var didStartSession = false

    init(session: SimulationSession) {
        self.session = session
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        buildMenu()
        configureDesktopMode()

        session.onUpdate = { [weak self] snapshot in
            self?.receive(snapshot)
        }
        didStartSession = true
        session.start()
        // The default surface is the click-through pet. The full experiment
        // window is created lazily from the status menu.
        showDesktopMode()
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.onUpdate = nil
        desktopMode?.stop()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        self.statusItem = nil
        session.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The status item is the app's persistent entry point; closing a
        // lazily-opened window must leave the pet and its menu alive.
        false
    }

    private func configureDesktopMode() {
        let desktop = DesktopModeController()
        desktop.onAction = { [weak self] action in
            self?.perform(action)
        }
        desktop.onShowBrain = { [weak self] in
            self?.showBrainInspector()
        }
        desktop.onBackToArena = { [weak self] in
            self?.hideDesktopMode()
        }
        desktop.onResize = { [weak self] size in
            guard let self, size.width > 0, size.height > 0 else { return }
            self.session.resize(width: Double(size.width), height: Double(size.height))
        }
        desktopMode = desktop
    }

    private func buildArenaWindow() {
        let controller = ArenaViewController()
        controller.onAction = { [weak self] action in
            self?.perform(action)
        }
        controller.onShowBrain = { [weak self] in
            self?.showBrainInspector()
        }
        controller.onShowDesktop = { [weak self] in
            self?.showDesktopMode()
        }
        controller.onResize = { [weak self] size in
            guard let self, self.didStartSession, self.desktopMode?.isActive != true,
                  size.width > 0, size.height > 0 else { return }
            self.session.resize(width: Double(size.width), height: Double(size.height))
        }
        arenaController = controller

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "NeuroFly · 연결 데이터 실험실"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 850, height: 620)
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.delegate = self
        arenaWindow = window
    }

    private func receive(_ snapshot: WorldSnapshot) {
        latestSnapshot = snapshot
        arenaController?.render(snapshot)
        brainInspector?.update(snapshot)
        desktopMode?.render(snapshot)
        pauseItem?.title = snapshot.isPaused ? "다시 시작" : "일시정지"
        petVisibilityItem?.title = desktopMode?.isActive == true && desktopMode?.isPetVisible == true ? "펫 숨기기" : "펫 보이기"
        updateDynamicMenus(snapshot)
    }

    private func perform(_ action: UserAction) {
        session.perform(action)
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "🪰"
        item.button?.toolTip = "NeuroFly"

        let menu = NSMenu()
        menu.autoenablesItems = false
        let foodMenuItem = NSMenuItem(title: "먹이 놓기", action: nil, keyEquivalent: "")
        let foodMenu = NSMenu(title: "먹이 놓기")
        foodMenu.addItem(statusMenuItem("바나나", action: #selector(placeBananaFromMenu)))
        foodMenu.addItem(statusMenuItem("베리", action: #selector(placeBerryFromMenu)))
        foodMenuItem.submenu = foodMenu
        menu.addItem(foodMenuItem)
        menu.addItem(statusMenuItem("그림자 드리우기", action: #selector(castShadowFromMenu)))
        menu.addItem(statusMenuItem("건드리기", action: #selector(touchFromMenu)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(statusMenuItem("상태 보기", action: #selector(showBrainFromMenu)))
        let add = statusMenuItem("개체 추가", action: #selector(addIndividualFromMenu))
        addIndividualItem = add
        menu.addItem(add)
        let remove = statusMenuItem("선택 개체 제거", action: #selector(removeIndividualFromMenu))
        removeIndividualItem = remove
        menu.addItem(remove)
        let selectParent = NSMenuItem(title: "개체 선택", action: nil, keyEquivalent: "")
        let selectMenu = NSMenu(title: "개체 선택")
        selectParent.submenu = selectMenu
        selectIndividualMenu = selectMenu
        selectIndividualMenuItem = selectParent
        menu.addItem(selectParent)
        let modelParent = NSMenuItem(title: "뇌 모델", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu(title: "뇌 모델")
        modelParent.submenu = modelMenu
        brainModelMenu = modelMenu
        brainModelMenuItem = modelParent
        menu.addItem(modelParent)
        let learning = statusMenuItem("먹이 기억 학습 켜기", action: #selector(toggleLearningFromMenu))
        learningItem = learning
        menu.addItem(learning)
        let forget = statusMenuItem("선택 개체 기억 지우기", action: #selector(clearMemoryFromMenu))
        clearMemoryItem = forget
        menu.addItem(forget)
        let pause = statusMenuItem("일시정지", action: #selector(togglePauseFromMenu))
        pauseItem = pause
        menu.addItem(pause)
        menu.addItem(statusMenuItem("전체 초기화", action: #selector(resetFromMenu)))
        menu.addItem(statusMenuItem("먹이 치우기", action: #selector(clearFoodFromMenu)))
        menu.addItem(NSMenuItem.separator())
        let visibility = statusMenuItem("펫 숨기기", action: #selector(togglePetFromMenu))
        petVisibilityItem = visibility
        menu.addItem(visibility)
        menu.addItem(statusMenuItem("실험실 열기", action: #selector(showArenaFromMenu)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(statusMenuItem("NeuroFly 종료", action: #selector(terminate)))
        item.menu = menu
        statusItem = item
        updateDynamicMenus(latestSnapshot)
    }

    private func statusMenuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func updateDynamicMenus(_ snapshot: WorldSnapshot) {
        let individuals = snapshot.individuals
        let individualIDs = individuals.map(\.id)
        let individualOrdinals = individuals.map(\.ordinal)
        if individualIDs != menuIndividualIDs || individualOrdinals != menuIndividualOrdinals {
            menuIndividualIDs = individualIDs
            menuIndividualOrdinals = individualOrdinals
            selectIndividualMenu?.removeAllItems()
            if individuals.isEmpty {
                let item = NSMenuItem(title: "개체 1", action: nil, keyEquivalent: "")
                item.isEnabled = false
                selectIndividualMenu?.addItem(item)
            } else {
                for individual in individuals {
                    let item = statusMenuItem("개체 \(individual.ordinal + 1)", action: #selector(selectIndividualFromMenu(_:)))
                    item.representedObject = individual.id
                    selectIndividualMenu?.addItem(item)
                }
            }
        }
        let isPreparing = !snapshot.isReady && snapshot.error == nil
        let individualActionsEnabled = !isPreparing && !individuals.isEmpty
        selectIndividualMenuItem?.isEnabled = !isPreparing && individuals.count > 1
        if !individuals.isEmpty {
            for (index, individual) in individuals.enumerated() {
                guard let item = selectIndividualMenu?.item(at: index) else { continue }
                item.title = "개체 \(individual.ordinal + 1)"
                item.state = individual.id == snapshot.selectedIndividualID ? .on : .off
                item.isEnabled = individualActionsEnabled && individuals.count > 1
            }
        }

        addIndividualItem?.isEnabled = snapshot.isReady && individuals.count < 4
        removeIndividualItem?.isEnabled = snapshot.isReady && individuals.count > 1
        clearMemoryItem?.isEnabled = individualActionsEnabled
        learningItem?.title = snapshot.memory.learningEnabled ? "먹이 기억 학습 끄기" : "먹이 기억 학습 켜기"
        learningItem?.state = snapshot.memory.learningEnabled ? .on : .off
        learningItem?.isEnabled = individualActionsEnabled

        let availableModels = snapshot.availableBrainModels
        if availableModels != menuBrainModels {
            menuBrainModels = availableModels
            brainModelMenu?.removeAllItems()
            for model in availableModels {
                let item = statusMenuItem(model.displayName, action: #selector(switchBrainModelFromMenu(_:)))
                item.representedObject = model.rawValue
                brainModelMenu?.addItem(item)
            }
        }
        for (index, model) in availableModels.enumerated() {
            brainModelMenu?.item(at: index)?.state = model == snapshot.brainModel ? .on : .off
            brainModelMenu?.item(at: index)?.isEnabled = snapshot.isReady || snapshot.error != nil
        }
        brainModelMenuItem?.isEnabled = !availableModels.isEmpty && (snapshot.isReady || snapshot.error != nil)
    }

    private func showBrainInspector() {
        if brainInspector == nil {
            let inspector = BrainInspectorController()
            inspector.onAction = { [weak self] action in
                self?.perform(action)
            }
            brainInspector = inspector
        }
        brainInspector?.update(latestSnapshot)
        if let window = brainInspector?.window {
            if window.isVisible == false {
                let visible = arenaWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                var origin: NSPoint
                if let arena = arenaWindow {
                    origin = NSPoint(x: arena.frame.maxX + 14, y: arena.frame.maxY - window.frame.height)
                } else {
                    origin = NSPoint(x: visible.midX - window.frame.width / 2,
                                     y: visible.midY - window.frame.height / 2)
                }
                origin.x = min(max(visible.minX, origin.x), visible.maxX - window.frame.width)
                origin.y = min(max(visible.minY, origin.y), visible.maxY - window.frame.height)
                window.setFrameOrigin(origin)
            }
        }
        brainInspector?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showDesktopMode() {
        guard let desktopMode else { return }
        arenaWindow?.orderOut(nil)
        if desktopMode.isActive == false {
            desktopMode.start(with: latestSnapshot)
        } else if desktopMode.isPetVisible == false {
            desktopMode.setPetVisible(true)
        }
    }

    private func hideDesktopMode() {
        desktopMode?.stop()
        if let size = arenaController?.scene.size, size.width > 0, size.height > 0 {
            session.resize(width: Double(size.width), height: Double(size.height))
        }
        arenaWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showArenaWindow() {
        if desktopMode?.isActive == true {
            desktopMode?.stop()
        }
        if arenaWindow == nil {
            buildArenaWindow()
        }
        arenaWindow?.center()
        arenaWindow?.makeKeyAndOrderFront(nil)
        arenaWindow?.contentView?.layoutSubtreeIfNeeded()
        if let size = arenaController?.scene.size, size.width > 0, size.height > 0 {
            session.resize(width: Double(size.width), height: Double(size.height))
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === arenaWindow else { return true }
        sender.orderOut(nil)
        showDesktopMode()
        return false
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: "NeuroFly", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(title: "NeuroFly 정보", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "NeuroFly 종료", action: #selector(terminate), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let viewMenuItem = NSMenuItem(title: "보기", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "보기")
        let brainItem = NSMenuItem(title: "뇌 보기", action: #selector(showBrainFromMenu), keyEquivalent: "b")
        brainItem.target = self
        viewMenu.addItem(brainItem)
        let desktopItem = NSMenuItem(title: "데스크톱 모드", action: #selector(showDesktopFromMenu), keyEquivalent: "d")
        desktopItem.target = self
        viewMenu.addItem(desktopItem)
        let arenaItem = NSMenuItem(title: "실험실 열기", action: #selector(showArenaFromMenu), keyEquivalent: "l")
        arenaItem.target = self
        viewMenu.addItem(arenaItem)
        let pauseItem = NSMenuItem(title: "일시정지 / 다시 시작", action: #selector(togglePauseFromMenu), keyEquivalent: "p")
        pauseItem.target = self
        viewMenu.addItem(pauseItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "NeuroFly"
        alert.informativeText = "현재 데이터셋의 신경 연결과 감각·운동 출력을 관찰하는 작은 실험실입니다.\n\n현재 몸체와 환경은 시뮬레이션으로 단순화되어 있습니다."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    @objc private func terminate() {
        NSApp.terminate(nil)
    }

    @objc private func showBrainFromMenu() {
        showBrainInspector()
    }

    @objc private func showDesktopFromMenu() {
        showDesktopMode()
    }

    @objc private func togglePauseFromMenu() {
        perform(.togglePause)
    }

    @objc private func placeFoodFromMenu() {
        placeFoodFromMenu(kind: .banana)
    }

    @objc private func placeBananaFromMenu() {
        placeFoodFromMenu(kind: .banana)
    }

    @objc private func placeBerryFromMenu() {
        placeFoodFromMenu(kind: .berry)
    }

    private func placeFoodFromMenu(kind: FoodKind) {
        showDesktopMode()
        desktopMode?.armPlacement(for: .food, foodKind: kind)
    }

    @objc private func castShadowFromMenu() {
        showDesktopMode()
        desktopMode?.armPlacement(for: .shadow)
    }

    @objc private func touchFromMenu() {
        showDesktopMode()
        desktopMode?.armPlacement(for: .touch)
    }

    @objc private func resetFromMenu() {
        perform(.reset)
    }

    @objc private func clearFoodFromMenu() {
        perform(.clearFood)
    }

    @objc private func addIndividualFromMenu() {
        perform(.addIndividual)
    }

    @objc private func removeIndividualFromMenu() {
        perform(.removeSelectedIndividual)
    }

    @objc private func selectIndividualFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        perform(.selectIndividual(id))
    }

    @objc private func toggleLearningFromMenu() {
        perform(.toggleLearning)
    }

    @objc private func clearMemoryFromMenu() {
        perform(.clearMemory)
    }

    @objc private func switchBrainModelFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let model = BrainModel(rawValue: rawValue) else { return }
        perform(.switchBrainModel(model))
    }

    @objc private func togglePetFromMenu() {
        guard let desktopMode else { return }
        guard desktopMode.isActive else { showDesktopMode(); return }
        desktopMode.setPetVisible(!desktopMode.isPetVisible)
        petVisibilityItem?.title = desktopMode.isPetVisible ? "펫 숨기기" : "펫 보이기"
    }

    @objc private func showArenaFromMenu() {
        showArenaWindow()
    }
}

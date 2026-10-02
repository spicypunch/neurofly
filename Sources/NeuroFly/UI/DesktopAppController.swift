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
    private var latestSnapshot = WorldSnapshot()
    private var didStartSession = false

    init(session: SimulationSession) {
        self.session = session
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
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
        window.title = "NeuroFly · FlyWire 실험실"
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
        menu.addItem(statusMenuItem("먹이 놓기", action: #selector(placeFoodFromMenu)))
        menu.addItem(statusMenuItem("그림자 드리우기", action: #selector(castShadowFromMenu)))
        menu.addItem(statusMenuItem("건드리기", action: #selector(touchFromMenu)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(statusMenuItem("상태 보기", action: #selector(showBrainFromMenu)))
        let pause = statusMenuItem("일시정지", action: #selector(togglePauseFromMenu))
        pauseItem = pause
        menu.addItem(pause)
        menu.addItem(statusMenuItem("초기화", action: #selector(resetFromMenu)))
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
    }

    private func statusMenuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
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
        alert.informativeText = "FlyWire v783 연결 데이터를 바탕으로 감각과 운동 출력을 관찰하는 작은 실험실입니다.\n\n현재 몸체와 환경은 시뮬레이션으로 단순화되어 있습니다."
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
        showDesktopMode()
        desktopMode?.armPlacement(for: .food)
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

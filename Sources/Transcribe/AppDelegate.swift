import AppKit
import ApplicationServices
import AVFoundation
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum RecognitionState {
        case idle
        case listening
        case transcribing
        case installing
        case downloading
    }

    private let appleSpeechService = SpeechRecognizerService()
    private let whisperRuntime = WhisperRuntimeManager()
    private lazy var whisperService = WhisperMLXService(runtimeManager: whisperRuntime)
    private let textInserter = TextInserter()
    private var keyMonitor: PushToTalkMonitor?
    private var permissionPollTimer: Timer?
    private var state: RecognitionState = .idle
    private var activeEngine: RecognitionEngine?

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var localOnlyMenuItem: NSMenuItem!
    private var whisperModelRootItem: NSMenuItem!
    private var whisperInstallMenuItem: NSMenuItem!
    private var whisperDownloadMenuItem: NSMenuItem!
    private var whisperStorageMenuItem: NSMenuItem!
    private var whisperStorageInfoMenuItem: NSMenuItem!
    private var whisperRevealStorageMenuItem: NSMenuItem!
    private var dictationMenuItem: NSMenuItem!
    private var engineMenuItems: [NSMenuItem] = []
    private var languageMenuItems: [NSMenuItem] = []
    private var whisperModelMenuItems: [NSMenuItem] = []

    private let languages: [(name: String, identifier: String)] = [
        ("简体中文", "zh-CN"),
        ("繁體中文", "zh-TW"),
        ("English (US)", "en-US"),
        ("日本語", "ja-JP")
    ]

    private var selectedEngine: RecognitionEngine {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: "recognitionEngine"),
                  let engine = RecognitionEngine(rawValue: rawValue) else {
                return .apple
            }
            return engine
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "recognitionEngine") }
    }

    private var selectedLocaleIdentifier: String {
        get { UserDefaults.standard.string(forKey: "recognitionLocale") ?? "zh-CN" }
        set { UserDefaults.standard.set(newValue, forKey: "recognitionLocale") }
    }

    private var selectedWhisperModel: WhisperModelOption {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: "whisperModel"),
                  let model = WhisperModelOption(rawValue: rawValue) else {
                return .small
            }
            return model
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "whisperModel") }
    }

    private var localRecognitionOnly: Bool {
        get {
            if UserDefaults.standard.object(forKey: "localRecognitionOnly") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "localRecognitionOnly")
        }
        set { UserDefaults.standard.set(newValue, forKey: "localRecognitionOnly") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        requestRequiredPermissions()
        installPushToTalkMonitor()
        startPermissionPolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionPollTimer?.invalidate()
        keyMonitor?.stop()
        appleSpeechService.cancel()
        whisperService.cancel()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Transcribe")
        statusItem.button?.toolTip = "Transcribe：按住右侧 Option 说话"

        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "正在检查权限…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        let shortcutItem = NSMenuItem(title: "按住右侧 Option 说话", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)
        menu.addItem(.separator())

        let engineRootItem = NSMenuItem(title: "识别引擎", action: nil, keyEquivalent: "")
        let engineMenu = NSMenu()
        for engine in RecognitionEngine.allCases {
            let item = NSMenuItem(
                title: engine.displayName,
                action: #selector(selectEngine(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = engine.rawValue
            engineMenu.addItem(item)
            engineMenuItems.append(item)
        }
        engineRootItem.submenu = engineMenu
        menu.addItem(engineRootItem)

        whisperModelRootItem = NSMenuItem(title: "Whisper 模型", action: nil, keyEquivalent: "")
        let whisperModelMenu = NSMenu()
        for model in WhisperModelOption.allCases {
            let item = NSMenuItem(
                title: model.displayName,
                action: #selector(selectWhisperModel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = model.rawValue
            whisperModelMenu.addItem(item)
            whisperModelMenuItems.append(item)
        }
        whisperModelRootItem.submenu = whisperModelMenu
        menu.addItem(whisperModelRootItem)

        whisperDownloadMenuItem = NSMenuItem(
            title: "下载所选 Whisper 模型…",
            action: #selector(downloadSelectedWhisperModel),
            keyEquivalent: ""
        )
        whisperDownloadMenuItem.target = self
        menu.addItem(whisperDownloadMenuItem)

        whisperInstallMenuItem = NSMenuItem(
            title: "安装 Whisper MLX…",
            action: #selector(installWhisperRuntime),
            keyEquivalent: ""
        )
        whisperInstallMenuItem.target = self
        menu.addItem(whisperInstallMenuItem)

        whisperStorageMenuItem = NSMenuItem(
            title: "设置 Whisper 存储位置…",
            action: #selector(selectWhisperStorageLocation),
            keyEquivalent: ""
        )
        whisperStorageMenuItem.target = self
        menu.addItem(whisperStorageMenuItem)

        whisperStorageInfoMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        whisperStorageInfoMenuItem.isEnabled = false
        menu.addItem(whisperStorageInfoMenuItem)

        whisperRevealStorageMenuItem = NSMenuItem(
            title: "在 Finder 中显示 Whisper 文件",
            action: #selector(revealWhisperStorage),
            keyEquivalent: ""
        )
        whisperRevealStorageMenuItem.target = self
        menu.addItem(whisperRevealStorageMenuItem)
        menu.addItem(.separator())

        let languageRootItem = NSMenuItem(title: "识别语言", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for language in languages {
            let item = NSMenuItem(
                title: language.name,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.identifier
            languageMenu.addItem(item)
            languageMenuItems.append(item)
        }
        languageRootItem.submenu = languageMenu
        menu.addItem(languageRootItem)

        localOnlyMenuItem = NSMenuItem(
            title: "Apple：仅使用本地识别",
            action: #selector(toggleLocalRecognition(_:)),
            keyEquivalent: ""
        )
        localOnlyMenuItem.target = self
        menu.addItem(localOnlyMenuItem)
        menu.addItem(.separator())

        let permissionsItem = NSMenuItem(
            title: "检查与申请权限…",
            action: #selector(checkPermissions),
            keyEquivalent: ""
        )
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        let accessibilityItem = NSMenuItem(
            title: "打开辅助功能设置…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        dictationMenuItem = NSMenuItem(
            title: "打开 Apple 听写设置…",
            action: #selector(openDictationSettings),
            keyEquivalent: ""
        )
        dictationMenuItem.target = self
        menu.addItem(dictationMenuItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Transcribe", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateMenuSelections()
    }

    private func requestRequiredPermissions() {
        let accessibilityOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(accessibilityOptions)

        if selectedEngine == .apple,
           SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                DispatchQueue.main.async { self?.refreshPermissionStatus() }
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshPermissionStatus() }
            }
        default:
            refreshPermissionStatus()
        }
    }

    private func installPushToTalkMonitor() {
        keyMonitor?.stop()

        let monitor = PushToTalkMonitor(
            onPress: { [weak self] in self?.beginListening() },
            onRelease: { [weak self] in self?.finishListening() }
        )

        keyMonitor = monitor.start() ? monitor : nil
        refreshPermissionStatus()
    }

    private func beginListening() {
        guard state == .idle else { return }

        guard requiredPermissionsAreGranted else {
            requestRequiredPermissions()
            startPermissionPolling()
            NSSound.beep()
            return
        }

        do {
            switch selectedEngine {
            case .apple:
                try appleSpeechService.start(
                    localeIdentifier: selectedLocaleIdentifier,
                    onDeviceOnly: localRecognitionOnly
                )
            case .whisperMLX:
                guard whisperRuntime.hasConfiguredStorageLocation,
                      whisperRuntime.isStorageAvailable else {
                    showWhisperInstallPrompt()
                    return
                }
                guard whisperRuntime.isInstalled else {
                    showWhisperInstallPrompt()
                    return
                }
                guard whisperRuntime.isModelDownloaded(selectedWhisperModel) else {
                    showWhisperModelDownloadPrompt()
                    return
                }
                try whisperService.start()
            }

            activeEngine = selectedEngine
            state = .listening
            setStatus(title: "正在听… · \(selectedEngine.displayName)", symbol: "mic.fill")
        } catch {
            activeEngine = nil
            state = .idle
            showError(error.localizedDescription)
        }
    }

    private func finishListening() {
        guard state == .listening, let activeEngine else { return }

        state = .transcribing
        setStatus(title: "正在转写… · \(activeEngine.displayName)", symbol: "ellipsis.bubble")

        let completion: (Result<String, Error>) -> Void = { [weak self] result in
            self?.handleTranscriptionResult(result, engine: activeEngine)
        }

        switch activeEngine {
        case .apple:
            appleSpeechService.finish(completion: completion)
        case .whisperMLX:
            whisperService.finish(
                localeIdentifier: selectedLocaleIdentifier,
                model: selectedWhisperModel,
                completion: completion
            )
        }
    }

    private func handleTranscriptionResult(
        _ result: Result<String, Error>,
        engine: RecognitionEngine
    ) {
        state = .idle
        activeEngine = nil

        switch result {
        case .success(let text):
            if text.isEmpty {
                setStatus(title: "没有识别到语音 · \(engine.displayName)", symbol: "mic")
            } else {
                textInserter.insert(text)
                setReadyStatus()
            }
        case .failure(let error):
            let isDictationDisabled: Bool
            if let serviceError = error as? SpeechRecognizerService.ServiceError,
               case .dictationDisabled = serviceError {
                isDictationDisabled = true
            } else {
                isDictationDisabled = false
            }
            showError(error.localizedDescription, offerDictationSettings: isDictationDisabled)
        }
    }

    private var requiredPermissionsAreGranted: Bool {
        guard AXIsProcessTrusted(),
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return false
        }
        return selectedEngine != .apple
            || SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    private func refreshPermissionStatus() {
        guard state == .idle else { return }

        if requiredPermissionsAreGranted && keyMonitor != nil {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
            setReadyStatus()
            updateMenuSelections()
            return
        }

        var missing: [String] = []
        if !AXIsProcessTrusted() { missing.append("辅助功能") }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { missing.append("麦克风") }
        if selectedEngine == .apple,
           SFSpeechRecognizer.authorizationStatus() != .authorized {
            missing.append("语音识别")
        }

        let title = missing.isEmpty ? "正在启用快捷键…" : "需要权限：\(missing.joined(separator: "、"))"
        setStatus(title: title, symbol: "mic.slash")
    }

    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil

        guard !requiredPermissionsAreGranted || keyMonitor == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.keyMonitor == nil && AXIsProcessTrusted() {
                self.installPushToTalkMonitor()
            } else {
                self.refreshPermissionStatus()
            }
        }
    }

    private func setReadyStatus() {
        guard selectedEngine == .whisperMLX else {
            setStatus(title: "就绪 · \(selectedEngine.displayName)", symbol: "mic")
            return
        }

        if !whisperRuntime.hasConfiguredStorageLocation {
            setStatus(title: "请设置 Whisper 存储位置", symbol: "questionmark.folder")
        } else if !whisperRuntime.isStorageAvailable {
            setStatus(title: "Whisper 存储位置不可用", symbol: "externaldrive.badge.exclamationmark")
        } else if !whisperRuntime.isInstalled {
            setStatus(title: "Whisper MLX 尚未安装", symbol: "arrow.down.circle")
        } else if !whisperRuntime.isModelDownloaded(selectedWhisperModel) {
            setStatus(title: "请下载 \(selectedWhisperModel.displayName)", symbol: "arrow.down.circle")
        } else {
            setStatus(title: "就绪 · \(selectedEngine.displayName)", symbol: "mic")
        }
    }

    private func setStatus(title: String, symbol: String) {
        statusMenuItem.title = title
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        statusItem.button?.contentTintColor = symbol == "mic.fill" ? .systemRed : .labelColor
        statusItem.button?.toolTip = "Transcribe：\(title)"
    }

    private func showError(_ message: String, offerDictationSettings: Bool = false) {
        let lastLine = message.split(whereSeparator: \.isNewline).last.map(String.init) ?? message
        let compactMessage = String(lastLine.prefix(120))
        setStatus(title: "出错：\(compactMessage)", symbol: "exclamationmark.triangle")
        NSSound.beep()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = offerDictationSettings ? "需要打开 macOS 听写" : "操作失败"
        alert.informativeText = message
        alert.addButton(withTitle: offerDictationSettings ? "打开听写设置" : "好")
        if offerDictationSettings {
            alert.addButton(withTitle: "稍后")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn && offerDictationSettings {
            openDictationSettings()
        }
    }

    private func showWhisperInstallPrompt() {
        guard !whisperRuntime.isBusy else {
            setStatus(title: "Whisper MLX 正在执行任务…", symbol: "arrow.down.circle")
            return
        }
        guard ensureWhisperStorageConfigured() else { return }
        if whisperRuntime.isInstalled {
            if whisperRuntime.isModelDownloaded(selectedWhisperModel) {
                setReadyStatus()
            } else {
                showWhisperModelDownloadPrompt()
            }
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "安装 Whisper MLX？"
        alert.informativeText = "应用将使用 uv 安装 mlx-whisper 0.4.3，运行环境约占 1 GB。\n\n存储位置：\(whisperRuntime.displayStoragePath)\n\n模型不会自动下载；安装运行环境后，你可以单独下载需要的模型。"
        alert.addButton(withTitle: "安装")
        alert.addButton(withTitle: "取消")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            installWhisperRuntime()
        }
    }

    private func showWhisperModelDownloadPrompt() {
        guard !whisperRuntime.isBusy else { return }
        guard ensureWhisperStorageConfigured() else { return }
        guard whisperRuntime.isInstalled else {
            showWhisperInstallPrompt()
            return
        }

        let alreadyDownloaded = whisperRuntime.isModelDownloaded(selectedWhisperModel)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = alreadyDownloaded ? "重新下载模型？" : "需要先下载模型"
        alert.informativeText = "模型：\(selectedWhisperModel.displayName)\n存储位置：\(whisperRuntime.displayStoragePath)\n\n下载完成前不能使用这个模型进行转写。"
        alert.addButton(withTitle: alreadyDownloaded ? "重新下载" : "下载")
        alert.addButton(withTitle: "取消")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            startWhisperModelDownload()
        }
    }

    private func ensureWhisperStorageConfigured() -> Bool {
        if whisperRuntime.hasConfiguredStorageLocation {
            guard !whisperRuntime.isStorageAvailable else { return true }

            let unavailableAlert = NSAlert()
            unavailableAlert.alertStyle = .warning
            unavailableAlert.messageText = "Whisper 存储位置不可用"
            unavailableAlert.informativeText = "请重新连接对应磁盘，或选择新的存储位置：\n\(whisperRuntime.storageURL.path)"
            unavailableAlert.addButton(withTitle: "选择新位置…")
            unavailableAlert.addButton(withTitle: "取消")
            NSApplication.shared.activate(ignoringOtherApps: true)
            return unavailableAlert.runModal() == .alertFirstButtonReturn
                && chooseWhisperStorageLocation()
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "选择 Whisper 存储位置"
        alert.informativeText = "运行环境、uv 缓存、Python 和所有模型都会保存在所选目录中。你也可以使用默认位置：\n\(whisperRuntime.defaultStorageURL.path)"
        alert.addButton(withTitle: "选择位置…")
        alert.addButton(withTitle: "使用默认位置")
        alert.addButton(withTitle: "取消")
        NSApplication.shared.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return chooseWhisperStorageLocation()
        case .alertSecondButtonReturn:
            do {
                try whisperRuntime.configureStorage(at: whisperRuntime.defaultStorageURL)
                updateMenuSelections()
                setReadyStatus()
                return true
            } catch {
                showError(error.localizedDescription)
                return false
            }
        default:
            return false
        }
    }

    @discardableResult
    private func chooseWhisperStorageLocation() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "选择 Whisper 存储位置"
        panel.message = "Transcribe 会在所选目录中创建 whisper-runtime、uv-python、uv-cache 和 models。"
        panel.prompt = "使用此位置"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if FileManager.default.fileExists(atPath: whisperRuntime.storageURL.path) {
            panel.directoryURL = whisperRuntime.storageURL
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            try whisperRuntime.configureStorage(at: url)
            updateMenuSelections()
            setReadyStatus()
            return true
        } catch {
            showError(error.localizedDescription)
            return false
        }
    }

    private func updateMenuSelections() {
        for item in engineMenuItems {
            item.state = (item.representedObject as? String == selectedEngine.rawValue) ? .on : .off
        }
        for item in languageMenuItems {
            item.state = (item.representedObject as? String == selectedLocaleIdentifier) ? .on : .off
        }
        for item in whisperModelMenuItems {
            guard let rawValue = item.representedObject as? String,
                  let model = WhisperModelOption(rawValue: rawValue) else { continue }
            item.state = model == selectedWhisperModel ? .on : .off
            item.title = model.displayName
                + (whisperRuntime.isModelDownloaded(model) ? " · 已下载" : " · 未下载")
        }

        let whisperSelected = selectedEngine == .whisperMLX
        let canModifyWhisper = state == .idle && !whisperRuntime.isBusy
        whisperModelRootItem.isEnabled = whisperSelected && canModifyWhisper
        whisperInstallMenuItem.isEnabled = whisperSelected && canModifyWhisper
        whisperInstallMenuItem.title = whisperRuntime.isInstalled
            ? "更新 Whisper MLX…"
            : "安装 Whisper MLX…"
        whisperDownloadMenuItem.isEnabled = whisperSelected
            && canModifyWhisper
            && whisperRuntime.isInstalled
        whisperDownloadMenuItem.title = whisperRuntime.isModelDownloaded(selectedWhisperModel)
            ? "重新下载 \(selectedWhisperModel.displayName)…"
            : "下载 \(selectedWhisperModel.displayName)…"
        whisperStorageMenuItem.isEnabled = canModifyWhisper
        whisperStorageInfoMenuItem.title = "存储位置：\(whisperRuntime.displayStoragePath)"
        whisperRevealStorageMenuItem.isEnabled = whisperRuntime.isStorageAvailable
        localOnlyMenuItem.isEnabled = !whisperSelected
        localOnlyMenuItem.state = localRecognitionOnly ? .on : .off
        dictationMenuItem.isEnabled = !whisperSelected
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard state == .idle,
              let rawValue = sender.representedObject as? String,
              let engine = RecognitionEngine(rawValue: rawValue) else { return }

        selectedEngine = engine
        updateMenuSelections()
        requestRequiredPermissions()
        refreshPermissionStatus()
        startPermissionPolling()

        if engine == .whisperMLX {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.whisperRuntime.hasConfiguredStorageLocation
                    || !self.whisperRuntime.isStorageAvailable
                    || !self.whisperRuntime.isInstalled {
                    self.showWhisperInstallPrompt()
                } else if !self.whisperRuntime.isModelDownloaded(self.selectedWhisperModel) {
                    self.showWhisperModelDownloadPrompt()
                }
            }
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        selectedLocaleIdentifier = identifier
        updateMenuSelections()
    }

    @objc private func selectWhisperModel(_ sender: NSMenuItem) {
        guard state == .idle,
              let rawValue = sender.representedObject as? String,
              let model = WhisperModelOption(rawValue: rawValue) else { return }
        selectedWhisperModel = model
        updateMenuSelections()
        setReadyStatus()

        if selectedEngine == .whisperMLX,
           whisperRuntime.isInstalled,
           !whisperRuntime.isModelDownloaded(model) {
            DispatchQueue.main.async { [weak self] in self?.showWhisperModelDownloadPrompt() }
        }
    }

    @objc private func toggleLocalRecognition(_ sender: NSMenuItem) {
        localRecognitionOnly.toggle()
        updateMenuSelections()
    }

    @objc private func installWhisperRuntime() {
        guard state == .idle else { return }
        guard ensureWhisperStorageConfigured() else { return }
        state = .installing
        setStatus(title: "正在安装 Whisper MLX…", symbol: "arrow.down.circle")
        updateMenuSelections()

        whisperRuntime.install { [weak self] result in
            guard let self else { return }
            self.state = .idle
            self.updateMenuSelections()

            switch result {
            case .success:
                self.setReadyStatus()
                let alert = NSAlert()
                alert.messageText = "Whisper MLX 安装完成"
                alert.informativeText = "运行环境已安装到：\n\(self.whisperRuntime.displayStoragePath)\n\n还需要下载模型才能使用 Whisper MLX。"
                alert.addButton(withTitle: "下载 \(self.selectedWhisperModel.displayName)")
                alert.addButton(withTitle: "稍后")
                NSApplication.shared.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    self.startWhisperModelDownload()
                }
            case .failure(let error):
                self.showError(error.localizedDescription)
            }
        }
    }

    @objc private func downloadSelectedWhisperModel() {
        guard state == .idle else { return }
        showWhisperModelDownloadPrompt()
    }

    private func startWhisperModelDownload() {
        guard state == .idle,
              whisperRuntime.isStorageAvailable,
              whisperRuntime.isInstalled else { return }
        let model = selectedWhisperModel
        state = .downloading
        setStatus(title: "正在下载 \(model.displayName)…", symbol: "arrow.down.circle")
        updateMenuSelections()

        whisperRuntime.download(model: model) { [weak self] result in
            guard let self else { return }
            self.state = .idle
            self.updateMenuSelections()

            switch result {
            case .success:
                self.setReadyStatus()
                let alert = NSAlert()
                alert.messageText = "Whisper 模型下载完成"
                alert.informativeText = "\(model.displayName) 已保存到：\n\(self.whisperRuntime.modelURL(for: model).path)\n\n现在可以按住右侧 Option 开始转写。"
                alert.addButton(withTitle: "好")
                NSApplication.shared.activate(ignoringOtherApps: true)
                alert.runModal()
            case .failure(let error):
                self.showError(error.localizedDescription)
            }
        }
    }

    @objc private func selectWhisperStorageLocation() {
        guard state == .idle else { return }
        guard chooseWhisperStorageLocation() else { return }
        if selectedEngine == .whisperMLX && !whisperRuntime.isInstalled {
            DispatchQueue.main.async { [weak self] in self?.showWhisperInstallPrompt() }
        }
    }

    @objc private func revealWhisperStorage() {
        guard whisperRuntime.isStorageAvailable else {
            showError("Whisper 存储位置不可用：\(whisperRuntime.storageURL.path)")
            return
        }
        NSWorkspace.shared.open(whisperRuntime.storageURL)
    }

    @objc private func checkPermissions() {
        requestRequiredPermissions()
        installPushToTalkMonitor()
        startPermissionPolling()
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openDictationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

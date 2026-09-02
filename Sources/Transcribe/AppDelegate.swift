import AppKit
import ApplicationServices
import AVFoundation
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum RecognitionState {
        case idle
        case listening
        case transcribing
    }

    private let speechService = SpeechRecognizerService()
    private let textInserter = TextInserter()
    private var keyMonitor: PushToTalkMonitor?
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var localOnlyMenuItem: NSMenuItem!
    private var languageMenuItems: [NSMenuItem] = []
    private var permissionPollTimer: Timer?
    private var state: RecognitionState = .idle
    private var permissionsWereRequested = false

    private let languages: [(name: String, identifier: String)] = [
        ("简体中文", "zh-CN"),
        ("繁體中文", "zh-TW"),
        ("English (US)", "en-US"),
        ("日本語", "ja-JP")
    ]

    private var selectedLocaleIdentifier: String {
        get { UserDefaults.standard.string(forKey: "recognitionLocale") ?? "zh-CN" }
        set { UserDefaults.standard.set(newValue, forKey: "recognitionLocale") }
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
        speechService.cancel()
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

        let languageItem = NSMenuItem(title: "识别语言", action: nil, keyEquivalent: "")
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
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        localOnlyMenuItem = NSMenuItem(
            title: "仅使用本地识别",
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

        let dictationItem = NSMenuItem(
            title: "打开听写设置…",
            action: #selector(openDictationSettings),
            keyEquivalent: ""
        )
        dictationItem.target = self
        menu.addItem(dictationItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Transcribe", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateMenuSelections()
    }

    private func requestRequiredPermissions() {
        guard !permissionsWereRequested else {
            refreshPermissionStatus()
            return
        }
        permissionsWereRequested = true

        let accessibilityOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(accessibilityOptions)

        SFSpeechRecognizer.requestAuthorization { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshPermissionStatus()
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refreshPermissionStatus()
                }
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

        if monitor.start() {
            keyMonitor = monitor
        } else {
            keyMonitor = nil
        }
        refreshPermissionStatus()
    }

    private func beginListening() {
        guard state == .idle else { return }

        guard requiredPermissionsAreGranted else {
            requestRequiredPermissions()
            NSSound.beep()
            return
        }

        do {
            try speechService.start(
                localeIdentifier: selectedLocaleIdentifier,
                onDeviceOnly: localRecognitionOnly
            )
            state = .listening
            setStatus(title: "正在听…", symbol: "mic.fill")
        } catch {
            state = .idle
            showError(error.localizedDescription)
        }
    }

    private func finishListening() {
        guard state == .listening else { return }

        state = .transcribing
        setStatus(title: "正在转写…", symbol: "ellipsis.bubble")

        speechService.finish { [weak self] result in
            guard let self else { return }
            self.state = .idle

            switch result {
            case .success(let text):
                if text.isEmpty {
                    self.setStatus(title: "没有识别到语音", symbol: "mic")
                } else {
                    self.textInserter.insert(text)
                    self.setStatus(title: "就绪", symbol: "mic")
                }
            case .failure(let error):
                let isDictationDisabled: Bool
                if let serviceError = error as? SpeechRecognizerService.ServiceError,
                   case .dictationDisabled = serviceError {
                    isDictationDisabled = true
                } else {
                    isDictationDisabled = false
                }
                self.showError(
                    error.localizedDescription,
                    offerDictationSettings: isDictationDisabled
                )
            }
        }
    }

    private var requiredPermissionsAreGranted: Bool {
        AXIsProcessTrusted()
            && SFSpeechRecognizer.authorizationStatus() == .authorized
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func refreshPermissionStatus() {
        guard state == .idle else { return }

        if requiredPermissionsAreGranted && keyMonitor != nil {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
            setStatus(title: "就绪", symbol: "mic")
            return
        }

        var missing: [String] = []
        if !AXIsProcessTrusted() { missing.append("辅助功能") }
        if SFSpeechRecognizer.authorizationStatus() != .authorized { missing.append("语音识别") }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { missing.append("麦克风") }

        setStatus(title: "需要权限：\(missing.joined(separator: "、"))", symbol: "mic.slash")
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

    private func setStatus(title: String, symbol: String) {
        statusMenuItem.title = title
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        statusItem.button?.toolTip = "Transcribe：\(title)"
    }

    private func showError(_ message: String, offerDictationSettings: Bool = false) {
        setStatus(title: "出错：\(message)", symbol: "exclamationmark.triangle")
        NSSound.beep()

        guard offerDictationSettings else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要打开 macOS 听写"
        alert.informativeText = message
        alert.addButton(withTitle: "打开听写设置")
        alert.addButton(withTitle: "稍后")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openDictationSettings()
        }
    }

    private func updateMenuSelections() {
        for item in languageMenuItems {
            item.state = (item.representedObject as? String == selectedLocaleIdentifier) ? .on : .off
        }
        localOnlyMenuItem.state = localRecognitionOnly ? .on : .off
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        selectedLocaleIdentifier = identifier
        updateMenuSelections()
    }

    @objc private func toggleLocalRecognition(_ sender: NSMenuItem) {
        localRecognitionOnly.toggle()
        updateMenuSelections()
    }

    @objc private func checkPermissions() {
        permissionsWereRequested = false
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

import ApplicationServices
import Foundation

final class PushToTalkMonitor {
    private let rightOptionKeyCode: CGKeyCode = 61
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    deinit {
        stop()
    }

    func start() -> Bool {
        guard eventTap == nil else { return true }

        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let monitor = Unmanaged<PushToTalkMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
        isPressed = false
    }

    private func handle(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard type == .flagsChanged, keyCode == rightOptionKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        let pressed = event.flags.contains(.maskAlternate)
        if pressed != isPressed {
            isPressed = pressed
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if pressed {
                    self.onPress()
                } else {
                    self.onRelease()
                }
            }
        }

        // Consume right Option so it acts only as push-to-talk while this app is running.
        return nil
    }
}

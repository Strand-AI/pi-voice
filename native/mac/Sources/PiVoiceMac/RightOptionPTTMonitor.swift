import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import IOKit
import PiVoiceMacCore

@MainActor
final class RightOptionPTTMonitor: ObservableObject {
    enum GlobalStatus: Equatable {
        case checking
        case ready
        case accessibilityRequired
        case monitorRegistrationFailed

        var label: String {
            switch self {
            case .checking: "Checking global Right Option…"
            case .ready: "Global Right Option monitors registered — hardware not yet verified"
            case .accessibilityRequired: "Global Right Option needs Accessibility"
            case .monitorRegistrationFailed: "Global Right Option monitor registration failed"
            }
        }

        var settingsName: String? { self == .accessibilityRequired ? "Accessibility" : nil }
    }

    @Published private(set) var globalStatus: GlobalStatus = .checking
    @Published private(set) var observedGlobalRightOption = false

    private var localFlagsMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var permissionWatchTask: Task<Void, Never>?
    private var gesture = GlobalOptionGesture()
    private var globalReceipt = GlobalRightOptionReceipt()
    private var activeGeneration: (() -> String?)?
    private var perform: ((GlobalOptionGestureAction) -> Void)?

    func install(
        activeGeneration: @escaping () -> String?,
        perform: @escaping (GlobalOptionGestureAction) -> Void
    ) {
        guard localFlagsMonitor == nil else { return }
        self.activeGeneration = activeGeneration
        self.perform = perform
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.observeModifiers(event, isGlobal: false)
            return event
        }
        recheckGlobalAccess()
    }

    func recheckGlobalAccess() {
        cancelActiveHold()
        removeGlobalMonitors()
        globalReceipt.reset()
        observedGlobalRightOption = false
        synchronizeReleasedOptionIfPossible()

        let hasAccessibilityAccess = AXIsProcessTrusted()
        guard shouldRegisterGlobalNSEventMonitor(accessibilityTrusted: hasAccessibilityAccess) else {
            globalStatus = .accessibilityRequired
            return
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.observeModifiers(event, isGlobal: true)
        }
        globalStatus = globalFlagsMonitor == nil ? .monitorRegistrationFailed : .ready
        updateKeyMonitors()
    }

    func handleApplicationResign() {
        guard shouldCancelOptionHoldOnApplicationResign(globalMonitorReady: globalStatus == .ready) else { return }
        cancelActiveHold()
    }

    func cancelActiveHold() {
        guard gesture.hasActiveHold else { return }
        if let action = gesture.accept(.nonModifierKeyDown, activeGeneration: activeGeneration?()) {
            perform?(action)
        }
        updateKeyMonitors()
    }

    /// Invalidates local physical authority without sending a second provider
    /// command. The coordinator owns any exact-generation recovery cancellation.
    func invalidateActiveHoldWithoutAction() {
        gesture.reset()
        updateKeyMonitors()
    }

    func remove() {
        cancelActiveHold()
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        removeGlobalMonitors()
        localFlagsMonitor = nil
        localKeyMonitor = nil
        permissionWatchTask?.cancel()
        permissionWatchTask = nil
        activeGeneration = nil
        perform = nil
        gesture.reset()
    }

    private func synchronizeReleasedOptionIfPossible() {
        guard !CGEventSource.keyState(.combinedSessionState, key: 61) else { return }
        _ = gesture.accept(
            .modifiers(optionDown: false, hasOtherModifiers: false),
            activeGeneration: activeGeneration?()
        )
    }

    private func observeModifiers(_ event: NSEvent, isGlobal: Bool) {
        globalReceipt.observe(keyCode: event.keyCode, isGlobal: isGlobal)
        observedGlobalRightOption = globalReceipt.observed
        let optionState = resolvePhysicalOptionState(
            deviceModifierFlags: event.modifierFlags.rawValue,
            leftOptionMask: UInt(NX_DEVICELALTKEYMASK),
            rightOptionMask: UInt(NX_DEVICERALTKEYMASK)
        )
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        emit(.modifiers(
            optionDown: optionState.rightDown,
            hasOtherModifiers: optionState.leftDown || !flags.subtracting(.option).isEmpty
        ))
    }

    private func observeKeyDown() {
        emit(.nonModifierKeyDown)
    }

    private func emit(_ event: GlobalOptionGestureEvent) {
        if let action = gesture.accept(event, activeGeneration: activeGeneration?()) {
            perform?(action)
        }
        updateKeyMonitors()
    }

    /// Key-down occurrence is observed only during an active Right Option hold.
    /// No character, key code, or event payload is read or retained.
    private func updateKeyMonitors() {
        if gesture.hasActiveHold {
            if localKeyMonitor == nil {
                localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined]) { [weak self] event in
                    self?.observeKeyDown()
                    return event
                }
            }
            if globalStatus == .ready, globalKeyMonitor == nil {
                globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .systemDefined]) { [weak self] _ in
                    self?.observeKeyDown()
                }
            }
            if shouldWatchGlobalAccessibility(
                activeHold: gesture.hasActiveHold,
                globalMonitorReady: globalStatus == .ready
            ), permissionWatchTask == nil {
                permissionWatchTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard let self, gesture.hasActiveHold else { return }
                        guard shouldRegisterGlobalNSEventMonitor(
                            accessibilityTrusted: AXIsProcessTrusted()
                        ) else {
                            globalStatus = .accessibilityRequired
                            cancelActiveHold()
                            return
                        }
                    }
                }
            }
            let monitorFailed = localKeyMonitor == nil || (globalStatus == .ready && globalKeyMonitor == nil)
            if monitorFailed {
                globalStatus = .monitorRegistrationFailed
                if let action = gesture.accept(.nonModifierKeyDown, activeGeneration: activeGeneration?()) {
                    perform?(action)
                }
                if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
                localKeyMonitor = nil
                permissionWatchTask?.cancel()
                permissionWatchTask = nil
                removeGlobalMonitors()
            }
        } else {
            if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
            if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
            localKeyMonitor = nil
            globalKeyMonitor = nil
            permissionWatchTask?.cancel()
            permissionWatchTask = nil
        }
    }

    private func removeGlobalMonitors() {
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        globalFlagsMonitor = nil
        globalKeyMonitor = nil
    }
}

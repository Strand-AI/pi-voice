import Foundation

public struct PhysicalOptionState: Equatable, Sendable {
    public let rightDown: Bool
    public let leftDown: Bool

    public init(rightDown: Bool, leftDown: Bool) {
        self.rightDown = rightDown
        self.leftDown = leftDown
    }
}

/// Device-dependent NSEvent flag bits preserve the two physical Option keys.
/// Reading them from the delivered event avoids racing an asynchronous global
/// monitor against a later session-wide key-state sample. The app passes the
/// SDK's NX_DEVICELALTKEYMASK and NX_DEVICERALTKEYMASK as the side masks.
public func resolvePhysicalOptionState(
    deviceModifierFlags: UInt,
    leftOptionMask: UInt,
    rightOptionMask: UInt
) -> PhysicalOptionState {
    PhysicalOptionState(
        rightDown: deviceModifierFlags & rightOptionMask != 0,
        leftDown: deviceModifierFlags & leftOptionMask != 0
    )
}

public struct GlobalRightOptionReceipt: Equatable, Sendable {
    public private(set) var observed = false

    public init() {}

    public mutating func observe(keyCode: UInt16, isGlobal: Bool) {
        if isGlobal, keyCode == 61 { observed = true }
    }

    public mutating func reset() { observed = false }
}

/// AppKit documents Accessibility trust as the authorization gate for global
/// key-related NSEvent monitors. Core Graphics listen-event access is not required.
public func shouldRegisterGlobalNSEventMonitor(accessibilityTrusted: Bool) -> Bool {
    accessibilityTrusted
}

public func shouldWatchGlobalAccessibility(activeHold: Bool, globalMonitorReady: Bool) -> Bool {
    activeHold && globalMonitorReady
}

public func shouldCancelOptionHoldOnApplicationResign(globalMonitorReady: Bool) -> Bool {
    !globalMonitorReady
}

public enum GlobalOptionGestureEvent: Equatable, Sendable {
    case modifiers(optionDown: Bool, hasOtherModifiers: Bool)
    case nonModifierKeyDown
}

public enum GlobalOptionGestureAction: Equatable, Sendable {
    case begin(generation: String)
    case end(generation: String, cancel: Bool)
}

/// Reduces listen-only keyboard observations into an exact-generation PTT gesture.
/// It never resolves a target and suppresses a gesture until Option is released after
/// any chord, unavailable session, or generation replacement.
public struct GlobalOptionGesture: Sendable {
    private var heldGeneration: String?
    private var optionDown = false
    private var suppressedUntilRelease = false

    public var hasActiveHold: Bool { heldGeneration != nil }

    public init() {}

    public mutating func accept(
        _ event: GlobalOptionGestureEvent,
        activeGeneration: String?
    ) -> GlobalOptionGestureAction? {
        if let heldGeneration, heldGeneration != activeGeneration {
            self.heldGeneration = nil
            suppressedUntilRelease = optionDown
        }

        switch event {
        case let .modifiers(isOptionDown, hasOtherModifiers):
            optionDown = isOptionDown

            guard isOptionDown else {
                defer {
                    heldGeneration = nil
                    suppressedUntilRelease = false
                }
                guard let heldGeneration, heldGeneration == activeGeneration else { return nil }
                return .end(generation: heldGeneration, cancel: false)
            }

            if hasOtherModifiers {
                suppressedUntilRelease = true
                guard let heldGeneration, heldGeneration == activeGeneration else {
                    self.heldGeneration = nil
                    return nil
                }
                self.heldGeneration = nil
                return .end(generation: heldGeneration, cancel: true)
            }

            guard !suppressedUntilRelease, heldGeneration == nil else { return nil }
            guard let activeGeneration else {
                suppressedUntilRelease = true
                return nil
            }
            heldGeneration = activeGeneration
            return .begin(generation: activeGeneration)

        case .nonModifierKeyDown:
            guard optionDown else { return nil }
            suppressedUntilRelease = true
            guard let heldGeneration, heldGeneration == activeGeneration else {
                self.heldGeneration = nil
                return nil
            }
            self.heldGeneration = nil
            return .end(generation: heldGeneration, cancel: true)
        }
    }

    public mutating func reset() {
        heldGeneration = nil
        optionDown = false
        suppressedUntilRelease = false
    }
}

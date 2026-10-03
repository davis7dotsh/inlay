import ApplicationServices
import Foundation

/// A menu command handle, not an AppKit object or a retained document snapshot.
/// Discovery finishes before the handle is transferred to the delivery actor.
struct NativePasteCommand: @unchecked Sendable {
    private let element: AXUIElement

    enum Attempt: Equatable, Sendable {
        case dispatched
        case unavailable
        case blocked
    }

    nonisolated static func find(for pid: pid_t) -> Self? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        guard pid > 0, !Task.isCancelled, AXIsProcessTrusted(),
              let menu = NativePasteAX.menuBar(for: pid) else { return nil }
        let discovery = NativePasteCommandDiscovery<AXUIElement>(
            metadata: { element in
                var owner: pid_t = 0
                guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return nil }
                return NativePasteAX.metadata(of: element)
            },
            children: NativePasteAX.children,
            sameElement: { CFEqual($0, $1) },
            now: { ProcessInfo.processInfo.systemUptime },
            isCancelled: { Task.isCancelled }
        )
        guard let element = discovery.find(in: menu, deadline: deadline) else { return nil }
        return Self(element: element)
    }

    /// The caller stages its clipboard transaction and validates original focus
    /// before invoking. Once dispatched, even an uncertain result forbids retry.
    nonisolated func invoke(canDispatch: () -> Bool) -> Attempt {
        NativePasteCommandInvocation<AXUIElement>(
            isTrusted: AXIsProcessTrusted,
            isCancelled: { Task.isCancelled },
            isCommand: { element in
                guard let metadata = NativePasteAX.metadata(of: element), metadata.isCommandV else { return .blocked }
                return .allowed
            },
            isEnabled: NativePasteAX.isEnabled,
            supportsPress: NativePasteAX.supportsPress,
            performPress: { element in
                AXUIElementSetMessagingTimeout(element, 0.2)
                return AXUIElementPerformAction(element, kAXPressAction as CFString)
            }
        ).invoke(element, canDispatch: canDispatch)
    }
}

struct NativePasteMenuMetadata {
    enum Role: String {
        case menuBar = "AXMenuBar"
        case menuBarItem = "AXMenuBarItem"
        case menu = "AXMenu"
        case menuItem = "AXMenuItem"
    }

    let role: Role
    let commandCharacter: String?
    let commandModifiers: UInt32?

    init(role: Role, commandCharacter: String? = nil, commandModifiers: UInt32? = nil) {
        self.role = role
        self.commandCharacter = commandCharacter
        self.commandModifiers = commandModifiers
    }

    var isCommandV: Bool {
        // AXMenuItemModifiers uses Command implicitly: zero means Cmd alone.
        role == .menuItem && commandCharacter?.lowercased() == "v" && commandModifiers == 0
    }
}

/// Pure traversal boundary: tests provide integer nodes, not real AX objects.
struct NativePasteCommandDiscovery<Element> {
    let metadata: (Element) -> NativePasteMenuMetadata?
    let children: (Element, Int) -> [Element]?
    let sameElement: (Element, Element) -> Bool
    let now: () -> TimeInterval
    let isCancelled: () -> Bool

    func find(in root: Element, deadline: TimeInterval, maximumNodes: Int = 128, maximumDepth: Int = 8) -> Element? {
        guard maximumNodes > 0, maximumDepth >= 0 else { return nil }
        var queue = [(root, 0)]
        var visited: [Element] = []
        var candidate: Element?
        while !queue.isEmpty {
            guard !isCancelled(), now() < deadline else { return nil }
            let (element, depth) = queue.removeFirst()
            if visited.contains(where: { sameElement($0, element) }) { continue }
            guard visited.count < maximumNodes, depth <= maximumDepth,
                  let item = metadata(element) else { return nil }
            if visited.isEmpty, item.role != .menuBar { return nil }
            visited.append(element)
            if item.role == .menuItem, item.commandCharacter?.lowercased() == "v" {
                // Missing modifiers could conceal a second Cmd-V command.
                guard item.commandModifiers != nil else { return nil }
                if item.isCommandV {
                    guard candidate == nil else { return nil }
                    candidate = element
                }
            }
            guard !isCancelled(), now() < deadline else { return nil }
            let remaining = maximumNodes - visited.count - queue.count
            guard remaining >= 0, let descendants = children(element, remaining),
                  descendants.count <= remaining,
                  descendants.isEmpty || depth < maximumDepth else { return nil }
            queue.append(contentsOf: descendants.map { ($0, depth + 1) })
        }
        // A candidate found before a timeout/truncated branch is not unique.
        guard !isCancelled(), now() < deadline else { return nil }
        return candidate
    }
}

enum NativePasteReadiness {
    case allowed
    case unavailable
    case blocked
}

struct NativePasteCommandInvocation<Element> {
    let isTrusted: () -> Bool
    let isCancelled: () -> Bool
    let isCommand: (Element) -> NativePasteReadiness
    let isEnabled: (Element) -> NativePasteReadiness
    let supportsPress: (Element) -> NativePasteReadiness
    let performPress: (Element) -> AXError

    func invoke(_ element: Element, canDispatch: () -> Bool) -> NativePasteCommand.Attempt {
        for check in [isCommand, isEnabled, supportsPress] {
            guard !isCancelled(), isTrusted() else { return .blocked }
            switch check(element) {
            case .allowed: break
            case .unavailable: return .unavailable
            case .blocked: return .blocked
            }
        }
        guard !isCancelled(), isTrusted(), canDispatch(), !isCancelled() else { return .blocked }
        switch performPress(element) {
        case .actionUnsupported, .notImplemented: return .unavailable
        case .apiDisabled, .invalidUIElement, .illegalArgument: return .blocked
        // Apple's API explicitly says cannotComplete may still have performed
        // the action. Treat any other uncertain response as sent, never retry.
        default: return .dispatched
        }
    }
}

private enum NativePasteAX {
    private static let readTimeout: Float = 0.025

    static func menuBar(for pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        let menu = attribute(kAXMenuBarAttribute as CFString, of: app)
        guard menu.verified, let value = menu.value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func metadata(of element: AXUIElement) -> NativePasteMenuMetadata? {
        let rawRole = attribute(kAXRoleAttribute as CFString, of: element)
        guard rawRole.verified, let roleName = rawRole.value as? String,
              let role = NativePasteMenuMetadata.Role(rawValue: roleName) else { return nil }
        guard role == .menuItem else { return NativePasteMenuMetadata(role: role) }
        let rawCharacter = attribute(kAXMenuItemCmdCharAttribute as CFString, of: element)
        guard rawCharacter.verified, rawCharacter.value == nil || rawCharacter.value as? String != nil else { return nil }
        let character = rawCharacter.value as? String
        guard character?.lowercased() == "v" else { return NativePasteMenuMetadata(role: role, commandCharacter: character) }
        let modifiers = attribute(kAXMenuItemCmdModifiersAttribute as CFString, of: element)
        guard modifiers.verified, let value = modifiers.value, CFGetTypeID(value) == CFNumberGetTypeID(),
              let number = value as? NSNumber, number.int64Value >= 0, number.int64Value <= Int64(UInt32.max),
              number.doubleValue == Double(number.int64Value) else { return nil }
        return NativePasteMenuMetadata(role: role, commandCharacter: character, commandModifiers: UInt32(number.int64Value))
    }

    static func children(of element: AXUIElement, limit: Int) -> [AXUIElement]? {
        guard !Task.isCancelled else { return nil }
        AXUIElementSetMessagingTimeout(element, readTimeout)
        var raw: CFArray?
        // Request one extra entry to distinguish a complete branch from a
        // truncated one. Never fetch an entire unbounded AXChildren array.
        let status = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, limit + 1, &raw)
        if status == .attributeUnsupported || status == .noValue { return [] }
        guard status == .success, let values = raw as? [AnyObject], values.count <= limit,
              values.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
        return values.map { $0 as! AXUIElement }
    }

    static func isEnabled(_ element: AXUIElement) -> NativePasteReadiness {
        let enabled = attribute(kAXEnabledAttribute as CFString, of: element)
        guard enabled.verified else { return .blocked }
        guard let value = enabled.value as? Bool else { return .unavailable }
        return value ? .allowed : .unavailable
    }

    static func supportsPress(_ element: AXUIElement) -> NativePasteReadiness {
        guard !Task.isCancelled else { return .blocked }
        AXUIElementSetMessagingTimeout(element, readTimeout)
        var raw: CFArray?
        let status = AXUIElementCopyActionNames(element, &raw)
        if status == .notImplemented || status == .actionUnsupported { return .unavailable }
        guard status == .success, let actions = raw as? [String] else { return .blocked }
        return actions.contains(kAXPressAction as String) ? .allowed : .unavailable
    }

    private static func attribute(_ name: CFString, of element: AXUIElement) -> (value: CFTypeRef?, verified: Bool) {
        guard !Task.isCancelled else { return (nil, false) }
        AXUIElementSetMessagingTimeout(element, readTimeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name, &value)
        if status == .attributeUnsupported || status == .noValue { return (nil, true) }
        return (value, status == .success && value != nil)
    }
}

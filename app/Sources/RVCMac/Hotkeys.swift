import AppKit
import Carbon.HIToolbox
import Foundation

enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case toggleRun, mute, bypass, pushToTalk, nextProfile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .toggleRun: return tr("Старт / стоп")
        case .mute: return "Mute"
        case .bypass: return tr("Без обработки (bypass)")
        case .pushToTalk: return tr("Push-to-talk (удерживать)")
        case .nextProfile: return tr("Следующий профиль")
        }
    }
}

/// A global shortcut: Carbon key code + Carbon modifier mask. Works without Accessibility permission.
struct Hotkey: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaults: [HotkeyAction: Hotkey] = [
        .mute: Hotkey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | optionKey)),
        .bypass: Hotkey(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | optionKey)),
        .toggleRun: Hotkey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey)),
    ]

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        let code = UInt32(event.keyCode)
        // plain keys would hijack typing everywhere; allow them only for function keys
        guard m != 0 || Self.functionKeys[code] != nil else { return nil }
        keyCode = code
        modifiers = m
    }

    private static let functionKeys: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19",
    ]

    private static let namedKeys: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Escape): "⎋",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_ANSI_Grave): "`",
    ]

    private static let letters: [UInt32: String] = {
        let pairs: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"),
            (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"),
            (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"), (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"), (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.map { (UInt32($0.0), $0.1) })
    }()

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += Self.functionKeys[keyCode] ?? Self.namedKeys[keyCode] ?? Self.letters[keyCode] ?? "#\(keyCode)"
        return s
    }
}

/// Registers global hotkeys through Carbon (RegisterEventHotKey), which reports both press and release.
final class HotkeyManager {
    static let shared = HotkeyManager()
    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var actionsByID: [UInt32: HotkeyAction] = [:]
    /// (action, pressed) on the main thread.
    var onEvent: ((HotkeyAction, Bool) -> Void)?
    private(set) var failures: [HotkeyAction] = []

    private init() {}

    private func installHandler() {
        guard handler == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, specs.count, &specs, nil, &handler)
    }

    /// Replaces all registrations. Returns the actions whose shortcut the system refused (taken by another app).
    @discardableResult
    func register(_ map: [HotkeyAction: Hotkey]) -> [HotkeyAction] {
        installHandler()
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actionsByID.removeAll()
        failures.removeAll()
        for (i, action) in HotkeyAction.allCases.enumerated() {
            guard let hk = map[action] else { continue }
            let id = EventHotKeyID(signature: OSType(0x5256_434D), id: UInt32(i + 1))  // 'RVCM'
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(hk.keyCode, hk.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref {
                refs[action] = ref
                actionsByID[id.id] = action
            } else {
                failures.append(action)
            }
        }
        return failures
    }

    fileprivate func handle(id: UInt32, pressed: Bool) {
        guard let action = actionsByID[id] else { return }
        onEvent?(action, pressed)
    }
}

private func hotkeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ user: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hk = EventHotKeyID()
    let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                               nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
    guard st == noErr else { return st }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    HotkeyManager.shared.handle(id: hk.id, pressed: pressed)
    return noErr
}

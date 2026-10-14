import Foundation
import Carbon
import AppKit

/// Action types triggered by keyboard shortcuts.
public enum ShortcutAction: String, CaseIterable, Sendable {
    case focusLeft = "Focus Left"
    case focusRight = "Focus Right"
    case focusUp = "Focus Up"
    case focusDown = "Focus Down"
    case moveColumnLeft = "Move Column Left"
    case moveColumnRight = "Move Column Right"
    case toggleZoom = "Toggle Zoom"
    case closeWindow = "Close Window"
    case cycleNext = "Cycle Next Window"
    case cyclePrev = "Cycle Previous Window"
    case scrollLeft = "Scroll Viewport Left"
    case scrollRight = "Scroll Viewport Right"
}

/// Global shortcut manager using native Carbon EventHotKey APIs.
@MainActor
public final class ShortcutManager {
    public static let shared = ShortcutManager()
    
    public var onShortcutTriggered: ((ShortcutAction) -> Void)?
    
    private var registeredHotKeys: [UInt32: (EventHotKeyRef, ShortcutAction)] = [:]
    private var eventHandlerRef: EventHandlerRef?
    
    public init() {
        installEventHandler()
    }
    
    // MARK: - Registration
    
    public func registerDefaultShortcuts() {
        unregisterAll()
        
        // Option key modifier: optionKey = 0x0800
        let opt = UInt32(optionKey)
        let optShift = UInt32(optionKey | shiftKey)
        
        // Carbon virtual key codes:
        // H = 0x04, L = 0x25, J = 0x26, K = 0x28, Enter = 0x24, W = 0x0D, Tab = 0x30
        // LeftArrow = 0x7B, RightArrow = 0x7C
        register(action: .focusLeft, keyCode: 0x04, modifiers: opt, id: 1) // Opt + H
        register(action: .focusRight, keyCode: 0x25, modifiers: opt, id: 2) // Opt + L
        register(action: .focusDown, keyCode: 0x26, modifiers: opt, id: 3) // Opt + J
        register(action: .focusUp, keyCode: 0x28, modifiers: opt, id: 4) // Opt + K
        register(action: .moveColumnLeft, keyCode: 0x04, modifiers: optShift, id: 5) // Opt + Shift + H
        register(action: .moveColumnRight, keyCode: 0x25, modifiers: optShift, id: 6) // Opt + Shift + L
        register(action: .toggleZoom, keyCode: 0x24, modifiers: opt, id: 7) // Opt + Enter
        register(action: .closeWindow, keyCode: 0x0D, modifiers: opt, id: 8) // Opt + W
        register(action: .cycleNext, keyCode: 0x30, modifiers: opt, id: 9) // Opt + Tab
        register(action: .cyclePrev, keyCode: 0x30, modifiers: optShift, id: 10) // Opt + Shift + Tab
        register(action: .scrollLeft, keyCode: 0x7B, modifiers: opt, id: 11) // Opt + Left
        register(action: .scrollRight, keyCode: 0x7C, modifiers: opt, id: 12) // Opt + Right
    }
    
    public func register(action: ShortcutAction, keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        let hotKeyID = EventHotKeyID(signature: OSType(0x49554D45), id: id) // 'IUME'
        var hotKeyRef: EventHotKeyRef?
        
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        if status == noErr, let ref = hotKeyRef {
            registeredHotKeys[id] = (ref, action)
        }
    }
    
    public func unregisterAll() {
        for (_, (ref, _)) in registeredHotKeys {
            UnregisterEventHotKey(ref)
        }
        registeredHotKeys.removeAll()
    }
    
    // MARK: - Private Event Handling
    
    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        let handler: EventHandlerUPP = { _, event, userData in
            guard let event = event, let userData = userData else { return noErr }
            let selfRef = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            
            if status == noErr {
                DispatchQueue.main.async {
                    selfRef.handleHotKey(id: hotKeyID.id)
                }
            }
            return noErr
        }
        
        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
    }
    
    private func handleHotKey(id: UInt32) {
        if let (_, action) = registeredHotKeys[id] {
            onShortcutTriggered?(action)
        }
    }
}

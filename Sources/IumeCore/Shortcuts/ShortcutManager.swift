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
    case cycleWidth = "Cycle Column Width"
    case centerColumn = "Center Column"
    case fullWidth = "Full Width"
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
        
        let opt = UInt32(optionKey)
        let optShift = UInt32(optionKey | shiftKey)
        let ctrlOpt = UInt32(controlKey | optionKey)
        let ctrlOptShift = UInt32(controlKey | optionKey | shiftKey)
        
        // Carbon virtual key codes:
        // H = 0x04, L = 0x25, J = 0x26, K = 0x28, Enter = 0x24, W = 0x0D, Tab = 0x30
        // R = 0x0F, C = 0x08, F = 0x03
        // LeftArrow = 0x7B, RightArrow = 0x7C, UpArrow = 0x7E, DownArrow = 0x7D
        
        // Directional Navigation (Option & Ctrl+Option)
        register(action: .focusLeft, keyCode: 0x04, modifiers: opt, id: 1) // Opt + H
        register(action: .focusRight, keyCode: 0x25, modifiers: opt, id: 2) // Opt + L
        register(action: .focusDown, keyCode: 0x26, modifiers: opt, id: 3) // Opt + J
        register(action: .focusUp, keyCode: 0x28, modifiers: opt, id: 4) // Opt + K
        
        register(action: .focusLeft, keyCode: 0x7B, modifiers: ctrlOpt, id: 5) // Ctrl + Opt + Left
        register(action: .focusRight, keyCode: 0x7C, modifiers: ctrlOpt, id: 6) // Ctrl + Opt + Right
        register(action: .focusDown, keyCode: 0x7D, modifiers: ctrlOpt, id: 7) // Ctrl + Opt + Down
        register(action: .focusUp, keyCode: 0x7E, modifiers: ctrlOpt, id: 8) // Ctrl + Opt + Up
        
        // Column Moving (Option+Shift & Ctrl+Option+Shift)
        register(action: .moveColumnLeft, keyCode: 0x04, modifiers: optShift, id: 9) // Opt + Shift + H
        register(action: .moveColumnRight, keyCode: 0x25, modifiers: optShift, id: 10) // Opt + Shift + L
        register(action: .moveColumnLeft, keyCode: 0x7B, modifiers: ctrlOptShift, id: 11) // Ctrl + Opt + Shift + Left
        register(action: .moveColumnRight, keyCode: 0x7C, modifiers: ctrlOptShift, id: 12) // Ctrl + Opt + Shift + Right
        
        // Window Control
        register(action: .toggleZoom, keyCode: 0x24, modifiers: opt, id: 13) // Opt + Enter
        register(action: .closeWindow, keyCode: 0x0D, modifiers: opt, id: 14) // Opt + W
        register(action: .cycleNext, keyCode: 0x30, modifiers: opt, id: 15) // Opt + Tab
        register(action: .cyclePrev, keyCode: 0x30, modifiers: optShift, id: 16) // Opt + Shift + Tab
        
        // Viewport Scrolling
        register(action: .scrollLeft, keyCode: 0x7B, modifiers: opt, id: 17) // Opt + Left
        register(action: .scrollRight, keyCode: 0x7C, modifiers: opt, id: 18) // Opt + Right
        
        // TileMyMac & ChainYourMac Sizing Shortcuts
        register(action: .cycleWidth, keyCode: 0x0F, modifiers: ctrlOpt, id: 19) // Ctrl + Opt + R (Cycle Width)
        register(action: .cycleWidth, keyCode: 0x0F, modifiers: opt, id: 20) // Opt + R
        
        register(action: .centerColumn, keyCode: 0x08, modifiers: ctrlOpt, id: 21) // Ctrl + Opt + C (Center)
        register(action: .centerColumn, keyCode: 0x08, modifiers: opt, id: 22) // Opt + C
        
        register(action: .fullWidth, keyCode: 0x03, modifiers: ctrlOpt, id: 23) // Ctrl + Opt + F (Full Width)
        register(action: .fullWidth, keyCode: 0x03, modifiers: opt, id: 24) // Opt + F
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

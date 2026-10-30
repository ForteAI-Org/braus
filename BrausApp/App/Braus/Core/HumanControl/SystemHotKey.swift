//
//  SystemHotKey.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import Carbon.HIToolbox
import OSLog

/// SystemHotKey is one key combination registered with the system through Carbon's
/// `RegisterEventHotKey`, which reaches Braus while another application is frontmost and needs no
/// Accessibility permission, unlike an event tap. `isRegistered` registers or unregisters it.
final class SystemHotKey {

    private let keyCode  : UInt32
    private let modifiers: UInt32
    private let onPress  : () -> Void

    // Unsafe only for deinit, which runs where the last owner let go: the main thread.
    nonisolated(unsafe) private var reference: EventHotKeyRef?
    nonisolated(unsafe) private var handler  : EventHandlerRef?

    private static let log = Logger(
        subsystem: "dev.forte.Braus",
        category : "HumanControl"
    )

    /// `keyCode` is a virtual key code (`kVK_…`), `modifiers` Carbon's (`controlKey | optionKey`).
    init(
        keyCode  : Int,
        modifiers: Int,
        onPress  : @escaping () -> Void
    ) {
        self.keyCode   = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        self.onPress   = onPress
    }

    var isRegistered: Bool {
        get { reference != nil }
        set { newValue ? register() : unregister() }
    }

    private func register() {
        guard reference == nil else { return }
        installHandler()
        var created: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &created
        )
        guard status == noErr, let created else {
            Self.log.error("hot key: not registered, status \(status, privacy: .public)")
            return
        }
        reference = created
    }

    private func unregister() {
        guard let reference else { return }
        UnregisterEventHotKey(reference)
        self.reference = nil
    }

    /// The handler stays installed for the key's life; only the registration comes and goes.
    private func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind : UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                // Carbon delivers hot keys on the main run loop.
                MainActor.assumeIsolated {
                    Unmanaged<SystemHotKey>.fromOpaque(context).takeUnretainedValue().onPress()
                }
                return noErr
            },
            1,
            &pressed,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        if status != noErr { Self.log.error("hot key: no handler, status \(status, privacy: .public)") }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// "BrHk", which tells Braus's hot keys from other applications'.
    private static let signature: OSType = 0x4272_486B
}

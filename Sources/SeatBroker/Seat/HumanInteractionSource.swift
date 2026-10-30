//
//  HumanInteractionSource.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import InteractionListener

/// HumanInteractionSource owns its stream and joins all callbacks when stopped.
@MainActor
protocol HumanInteractionSource: AnyObject {
    var events: AsyncThrowingStream<InteractionEvent, any Error> { get }
    var buttons: InteractionButtonState { get }
    var observationRevision: UInt64? { get }
    func stop() async
}

extension HumanInteractionSource {
    var observationRevision: UInt64? { nil }
}

extension PassiveInteractionListener: HumanInteractionSource {
    var observationRevision: UInt64? { revision }
}


/// ObservedInteractionSource hands every event of `source` to `observe` in order, then passes it on
/// for recording, hovers excepted: only the activity policy reads them. Stopping stops `source` and
/// joins the forwarding.
@MainActor
final class ObservedInteractionSource: HumanInteractionSource {
    let events: AsyncThrowingStream<InteractionEvent, any Error>
    private let source: any HumanInteractionSource
    private let forwarding: Task<Void, Never>

    var buttons: InteractionButtonState { source.buttons }
    var observationRevision: UInt64? { source.observationRevision }

    init(
        _ source: any HumanInteractionSource,
        observe : @escaping @MainActor (InteractionEvent) -> Void
    ) {
        let (events, continuation) = AsyncThrowingStream<InteractionEvent, any Error>.makeStream()
        self.events = events
        self.source = source
        let inner = source.events
        forwarding = Task {
            do {
                for try await event in inner {
                    observe(event)
                    if event.kind != .hover { continuation.yield(event) }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func stop() async {
        await source.stop()
        await forwarding.value
    }
}

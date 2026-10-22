//
//  RoomDenoiserPool.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import CoreGraphics
import Foundation
import Metal

/// RoomDenoiserInterest keeps availability-specific resources out of the macOS 15 renderer's storage.
@MainActor
protocol RoomDenoiserInterest: AnyObject {
    var size   : CGSize { get }
    var isReady: Bool { get }
    func cancel()
}

/// RoomDenoiserPool prepares one scaler pair per 64-pixel bucket away from the main actor.
///
/// The six-entry limit includes construction and GPU loans. Creation is serial, and each pair is
/// loaned exclusively until command-buffer completion. Unused entries are released; under pressure
/// the least recently borrowed idle entry is evicted. A newly prepared entry gets its first loan
/// before eviction, so a burst of requests cannot evict it before its queued room renders.
@available(macOS 26, *)
@MainActor
final class RoomDenoiserPool {
    static let shared = RoomDenoiserPool()

    let capacity: Int

    /// Bucket rounds both output dimensions upward; the input is 0.75 of each dimension.
    nonisolated struct Bucket: Hashable, Sendable {
        let deviceID: UInt64
        let width   : Int
        let height  : Int

        init(
            deviceID: UInt64,
            width   : Int,
            height  : Int
        ) {
            self.deviceID = deviceID
            self.width    = ((max(1, width) - 1) / 64 + 1) * 64
            self.height   = ((max(1, height) - 1) / 64 + 1) * 64
        }

        var size: CGSize {
            CGSize(
                width : width,
                height: height
            )
        }
    }

    /// Request keeps a room's interest alive, but never owns a scaler or its GPU history.
    final class Request: RoomDenoiserInterest {
        let bucket: Bucket

        fileprivate let id            = UUID()
        fileprivate let device        : MTLDevice
        fileprivate var needsResource = true
        fileprivate var waitsForLoan  = true
        fileprivate let onReady       : @MainActor () -> Void

        private let pool: RoomDenoiserPool

        fileprivate init(
            bucket : Bucket,
            device : MTLDevice,
            pool   : RoomDenoiserPool,
            onReady: @escaping @MainActor () -> Void
        ) {
            self.bucket  = bucket
            self.device  = device
            self.pool    = pool
            self.onReady = onReady
        }

        var isReady: Bool { pool.isReady(bucket) }
        var size   : CGSize { bucket.size }

        func borrow() -> RoomDenoiser? { pool.borrow(self) }

        func giveBack(_ resource: RoomDenoiser) { pool.giveBack(resource) }

        func prepare() {
            guard !isReady else { return }
            waitsForLoan  = true
            needsResource = pool.entries[bucket] == nil
            pool.pump()
        }

        func cancel() { pool.remove(id) }

        deinit {
            let pool = pool
            let id   = id
            Task { @MainActor in pool.remove(id) }
        }
    }

    private struct Interest {
        let id: UUID
        weak var request: Request?
    }

    private struct Entry {
        var resource  : RoomDenoiser?
        var isCreating = true
        var isBorrowed = false
        var lastUse    = 0
    }

    private var entries   : [Bucket: Entry] = [:]
    private var interests : [Interest] = []
    private var isCreating = false
    private var clock      = 0
    private let create    : @Sendable (MTLDevice, Bucket) -> RoomDenoiser?

    /// Counts every resident pair, including a pair being created or used by the GPU.
    var count: Int { entries.count }

    init(
        capacity: Int = 6,
        create  : @escaping @Sendable (MTLDevice, Bucket) -> RoomDenoiser? = { device, bucket in
            RoomDenoiser(
                device: device,
                width : bucket.width,
                height: bucket.height
            )
        }
    ) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.create   = create
    }

    /// Starts prewarming as soon as layout knows the output size. The callback runs on the main
    /// actor only when a pending room can retry its render; it must not encode inline.
    func request(
        device : MTLDevice,
        width  : Int,
        height : Int,
        onReady: @escaping @MainActor () -> Void
    ) -> Request {
        let bucket = Bucket(
            deviceID: device.registryID,
            width   : width,
            height  : height
        )
        let request = Request(
            bucket : bucket,
            device : device,
            pool   : self,
            onReady: onReady
        )
        interests.append(Interest(
            id     : request.id,
            request: request
        ))
        if entries[bucket] != nil { request.needsResource = false }
        pump()
        return request
    }

    private func isReady(_ bucket: Bucket) -> Bool {
        guard let entry = entries[bucket] else { return false }
        return entry.resource != nil && !entry.isBorrowed
    }

    private func borrow(_ request: Request) -> RoomDenoiser? {
        guard let resource = entries[request.bucket]?.resource, isReady(request.bucket) else {
            request.waitsForLoan  = true
            request.needsResource = entries[request.bucket] == nil
            pump()
            return nil
        }
        clock += 1
        entries[request.bucket]?.lastUse    = clock
        entries[request.bucket]?.isBorrowed = true
        request.waitsForLoan = false
        return resource
    }

    /// Returns a loan only after the command buffer finishes, including error completion.
    func giveBack(_ resource: RoomDenoiser) {
        let bucket = Bucket(
            deviceID: resource.device.registryID,
            width   : resource.width,
            height  : resource.height
        )
        guard entries[bucket]?.resource === resource else { return }
        entries[bucket]?.isBorrowed = false
        prune()
        notify(bucket)
        pump()
    }

    private func remove(_ id: UUID) {
        interests.removeAll { $0.id == id || $0.request == nil }
        prune()
        pump()
    }

    private func prune() {
        interests.removeAll { $0.request == nil }
        let wanted = Set(interests.compactMap { $0.request?.bucket })
        entries = entries.filter { key, entry in
            wanted.contains(key) || entry.isCreating || entry.isBorrowed
        }
    }

    private func notify(_ bucket: Bucket) {
        guard isReady(bucket) else { return }
        let waiting = interests.compactMap(\.request).filter {
            $0.bucket == bucket && $0.waitsForLoan
        }
        for request in waiting {
            request.waitsForLoan = false
            request.onReady()
        }
    }

    private func pump() {
        prune()
        guard !isCreating else { return }
        guard let request = interests.compactMap(\.request).first(where: { $0.needsResource }) else { return }
        let bucket = request.bucket
        if entries[bucket] != nil {
            request.needsResource = false
            pump()
            return
        }
        if entries.count == capacity {
            let oldest = entries.filter {
                !$0.value.isCreating && !$0.value.isBorrowed
                    && ($0.value.lastUse > 0 || $0.value.resource == nil)
            }.min { $0.value.lastUse < $1.value.lastUse }
            guard let oldest else { return }
            entries.removeValue(forKey: oldest.key)
        }
        for interest in interests.compactMap(\.request) where interest.bucket == bucket {
            interest.needsResource = false
        }
        entries[bucket] = Entry()
        isCreating = true
        let device = request.device
        let create = create
        Task { [self] in
            let resource = await Task.detached(priority: .utility) {
                precondition(!Thread.isMainThread)
                return create(device, bucket)
            }.value
            entries[bucket]?.resource   = resource
            entries[bucket]?.isCreating = false
            isCreating = false
            prune()
            notify(bucket)
            pump()
        }
    }
}

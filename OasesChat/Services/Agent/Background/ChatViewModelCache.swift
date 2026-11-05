import Foundation
import SwiftData
import UIKit

private let cacheLogger = AppLogger(category: "ViewModelCache")

/// Caches `ChatViewModel` instances by conversation id so a headless App Intent
/// and the UI drive the *same* view model for a session.
///
/// Ported from OpenMinis `ChatLifecycleSupport.swift::ViewModelCache`, including
/// its LRU soft cap and memory-warning eviction. Two deliberate differences:
///
///   - OpenMinis keys on its own session-id strings and rehydrates from SQLite.
///     OasesChat keys on `ConversationModel.id` and rehydrates through
///     `ConversationContainer` + `load(conversation:)`.
///   - OpenMinis' staleness set exists to catch inbound iCloud merges landing on
///     a cached VM. There is no sync engine here, so that half is omitted rather
///     than carried as dead state.
///
/// A view model that is mid-stream is never evicted — its send loop must finish.
@MainActor
final class ChatViewModelCache {
    static let shared = ChatViewModelCache()

    private var cache: [String: ChatViewModel] = [:]
    /// Least-recently-used → most-recently-used. Kept in sync with `cache`.
    private var lruOrder: [String] = []

    /// Soft cap on cached view models. Beyond this the least-recently-used
    /// non-streaming entries are evicted; re-entering rebuilds from SwiftData.
    private static let softCap = 6

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evictOnMemoryWarning() }
        }
    }

    /// Existing view model for the conversation, or a freshly hydrated one.
    /// Returns `isNew` so callers can skip a redundant reload.
    @discardableResult
    func getOrCreate(for conversationId: String) -> (vm: ChatViewModel, isNew: Bool) {
        if let existing = cache[conversationId] {
            touch(conversationId)
            return (existing, false)
        }

        let vm = ChatViewModel()
        let context = ModelContext(ConversationContainer.shared)
        vm.bind(context: context)
        if let uuid = UUID(uuidString: conversationId),
           let conversation = ConversationContainer.conversation(id: uuid) {
            vm.load(conversation: conversation)
        }
        cache[conversationId] = vm
        touch(conversationId)
        cacheLogger.info("created vm for conversation=\(conversationId.prefix(8))")
        evictIfNeeded()
        return (vm, true)
    }

    func get(for conversationId: String) -> ChatViewModel? {
        guard let vm = cache[conversationId] else { return nil }
        touch(conversationId)
        return vm
    }

    /// Read whether a view model is cached without promoting it in the LRU.
    /// Debug status probes use this alongside `isStreaming`.
    func hasCached(conversationId: String) -> Bool {
        cache[conversationId] != nil
    }

    /// Whether a *cached* view model for this conversation is mid-stream.
    ///
    /// Deliberately does NOT `touch()` the LRU: this is the liveness probe the
    /// sessions CLI polls, and a status read shouldn't promote an entry ahead of
    /// view models the user is actually using. `false` for an uncached session —
    /// nothing can be streaming without a live view model.
    func isStreaming(conversationId: String) -> Bool {
        cache[conversationId]?.isStreaming ?? false
    }

    /// A view model for a conversation that doesn't exist yet. The caller is
    /// responsible for inserting the `ConversationModel` and then calling
    /// `adopt` so subsequent lookups hit the same instance.
    func createDraft() -> ChatViewModel {
        let vm = ChatViewModel()
        vm.bind(context: ModelContext(ConversationContainer.shared))
        return vm
    }

    func adopt(_ vm: ChatViewModel, conversationId: String) {
        cache[conversationId] = vm
        touch(conversationId)
        evictIfNeeded()
    }

    func remove(conversationId: String) {
        cache.removeValue(forKey: conversationId)
        lruOrder.removeAll { $0 == conversationId }
    }

    // MARK: - LRU

    private func touch(_ id: String) {
        lruOrder.removeAll { $0 == id }
        lruOrder.append(id)
    }

    private func isEvictable(_ vm: ChatViewModel) -> Bool {
        !vm.isStreaming
    }

    private func evictIfNeeded() {
        guard cache.count > Self.softCap else { return }
        for id in lruOrder {
            guard cache.count > Self.softCap else { break }
            guard let vm = cache[id], isEvictable(vm) else { continue }
            remove(conversationId: id)
            cacheLogger.info("evicted (soft cap) conversation=\(id.prefix(8))")
        }
    }

    private func evictOnMemoryWarning() {
        let before = cache.count
        for (id, vm) in cache where isEvictable(vm) {
            remove(conversationId: id)
        }
        cacheLogger.info("memory warning: evicted \(before - cache.count) of \(before)")
    }
}

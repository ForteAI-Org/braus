import Synchronization

extension MemoryService {
    /// PersonEpisodes counts open person episodes in this process, independently of any archive.
    public enum PersonEpisodes {
        private static let count = Mutex(0)

        public static func began() { count.withLock { $0 += 1 } }
        public static func ended() { count.withLock { $0 = max(0, $0 - 1) } }
        public static var anyOpen: Bool { count.withLock { $0 > 0 } }
    }
}

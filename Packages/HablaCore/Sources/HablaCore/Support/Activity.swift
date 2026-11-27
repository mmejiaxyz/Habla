import Foundation

/// One thing moving or being made: a book being received or sent, narrated, imported. Sync and
/// narration report these so the app can show what is happening (and why something waits).
public struct ActivityItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case getting, sending, narrating, importing }
    public enum State: Equatable, Sendable {
        /// 0…1 when known.
        case running(Double?)
        /// Not started or held back, with the plain reason ("Waiting for room on the cloud").
        case waiting(String)
        /// Stopped, with what happened and what was kept ("The connection dropped. 180 MB kept.").
        case failed(String)
        case done
    }

    public var id: String
    public var bookID: String?
    public var title: String?
    public var kind: Kind
    public var state: State
    /// How it travels ("Wi-Fi · from MacBook Pro", "Cloud").
    public var route: String?
    public var updatedAt: Date

    public init(id: String, bookID: String? = nil, title: String? = nil, kind: Kind, state: State,
                route: String? = nil, updatedAt: Date = Date()) {
        self.id = id; self.bookID = bookID; self.title = title; self.kind = kind; self.state = state
        self.route = route; self.updatedAt = updatedAt
    }

    public var isFinished: Bool { if case .done = state { return true }; return false }
}

extension Array where Element == ActivityItem {
    /// Adds or replaces an item (same id), newest first; finished items go after a day.
    public mutating func note(_ item: ActivityItem) {
        var item = item
        if let i = firstIndex(where: { $0.id == item.id }) {
            if item.title == nil { item.title = self[i].title }
            if item.route == nil { item.route = self[i].route }
            self[i] = item                                   // in place: rows don't jump around
        } else {
            insert(item, at: 0)
        }
        let dayAgo = Date().addingTimeInterval(-86400)
        removeAll { $0.isFinished && $0.updatedAt < dayAgo }
        if count > 40 { removeLast(count - 40) }
    }
}

//
//  PostCollection.swift
//  Braus
//

import Foundation

/// PostCollectionRequest bounds one collection of the posts or articles of the page a web session holds: how many
/// distinct ones are wanted, how many times the page may be scrolled for more, and for how long.
nonisolated public struct PostCollectionRequest: Sendable, Equatable {

    public static let targets  = 1...200
    public static let scrolls  = 0...100
    public static let seconds  = 1.0...180.0
    /// `seconds` in whole seconds, as the tool takes them.
    public static let wholeSeconds = 1...180

    public let target    : Int
    public let maxScrolls: Int
    public let seconds   : Double

    /// Clamps each bound to its range.
    public init(target: Int, maxScrolls: Int = 30, seconds: Double = 60) {
        self.target     = min(max(target, Self.targets.lowerBound), Self.targets.upperBound)
        self.maxScrolls = min(max(maxScrolls, Self.scrolls.lowerBound), Self.scrolls.upperBound)
        self.seconds    = min(max(seconds, Self.seconds.lowerBound), Self.seconds.upperBound)
    }
}

/// CollectedQuote is a post quoted inside another, kept apart from it: its author and text are never the quoting
/// post's. Its text is bounded as a post's is, and says so.
nonisolated public struct CollectedQuote: Sendable, Equatable {
    public let author    : String?
    public let handle    : String?
    public let text      : String
    public let textLength: Int
    public let truncated : Bool
    public let url       : String?

    public init(author: String?, handle: String?, text: String, textLength: Int, truncated: Bool, url: String?) {
        self.author     = author
        self.handle     = handle
        self.text       = text
        self.textLength = textLength
        self.truncated  = truncated
        self.url        = url
    }
}

/// CollectedPost is one post or article as the page's own content showed it: its identity (the site's ID or its
/// link), author, full text, link and date when the page gives them, and where it was read.
///
/// The text is the page's, whole: `textLength` is its length, and `truncated` says when Braus kept only the first
/// `CollectedPost.textLimit` characters of a longer one. `shortenedBySite` says when the page itself shows only the
/// start of the text (a "Show more" link), which Braus cannot read past without opening the post.
nonisolated public struct CollectedPost: Sendable, Equatable {

    /// The most characters of one post's text, or a quote's, an answer carries.
    public static let textLimit  = 8_000
    /// The most characters of a name, handle, link, date or context.
    public static let fieldLimit = 300

    public let identity       : String
    /// The rule that read it: `x`, `reddit` or `article`.
    public let source         : String
    public let author         : String?
    public let handle         : String?
    public let text           : String
    public let textLength     : Int
    public let truncated      : Bool
    public let shortenedBySite: Bool
    public let url            : String?
    public let time           : String?
    /// What the page says around the post, such as who reposted it.
    public let context        : String?
    public let quote          : CollectedQuote?
    /// A name, handle, link, date or context was longer than `fieldLimit` and only its start is kept.
    public let fieldsClipped  : Bool
    /// The read that first found it: 0 before any scroll.
    public let round          : Int

    public init(identity: String, source: String, author: String?, handle: String?, text: String, textLength: Int,
                truncated: Bool, shortenedBySite: Bool, url: String?, time: String?, context: String?,
                quote: CollectedQuote?, fieldsClipped: Bool = false, round: Int) {
        self.identity        = identity
        self.source          = source
        self.author          = author
        self.handle          = handle
        self.text            = text
        self.textLength      = textLength
        self.truncated       = truncated
        self.shortenedBySite = shortenedBySite
        self.url             = url
        self.time            = time
        self.context         = context
        self.quote           = quote
        self.fieldsClipped   = fieldsClipped
        self.round           = round
    }
}

/// Why a collection stopped.
nonisolated public enum PostCollectionStop: String, Sendable, Equatable {
    /// As many distinct posts as asked.
    case targetReached = "target_reached"
    /// The page showed no new post after several scrolls, short of its end.
    case noProgress    = "no_progress"
    /// The page cannot scroll further and shows no new post.
    case endOfPage     = "end_of_page"
    case deadline
    case maxScrolls    = "max_scrolls"
    /// The page holds more than one read takes (posts, characters or nodes), and scrolling brought nothing new.
    case readLimit     = "read_limit"
    /// The page holds nothing the reader knows as a post or an article.
    case unsupported
    /// The session could not go on (its profile changed or disconnected, the page closed): what was read is kept,
    /// and nothing more was sent.
    case interrupted
}

/// PostCollection is what one collection read: the distinct posts in the order first found, why it stopped, and how.
nonisolated public struct PostCollection: Sendable, Equatable {
    public let pageURL : String
    /// The reader the page matched: `x`, `reddit`, `article` or `none`.
    public let site    : String
    public let posts   : [CollectedPost]
    public let stop    : PostCollectionStop
    /// The stop in words, with what it means for the agent.
    public let reason  : String
    public let target  : Int
    public let scrolls : Int
    public let reads   : Int

    public init(pageURL: String, site: String, posts: [CollectedPost], stop: PostCollectionStop, reason: String,
                target: Int, scrolls: Int, reads: Int) {
        self.pageURL = pageURL
        self.site    = site
        self.posts   = posts
        self.stop    = stop
        self.reason  = reason
        self.target  = target
        self.scrolls = scrolls
        self.reads   = reads
    }

    /// Fewer posts than asked.
    public var isPartial: Bool { posts.count < target }
}

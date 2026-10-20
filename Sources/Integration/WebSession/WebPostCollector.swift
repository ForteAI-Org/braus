//
//  WebPostCollector.swift
//  Braus
//

import AutomationRuntime
import Foundation
import WebDriver

/// WebPostCollector reads the posts or articles of the page a web session holds, in bulk, and scrolls it for more
/// until it has as many distinct ones as asked or has a reason to stop, which it says.
///
/// Each read runs `script`, fixed in Braus and never written by the model, on the page: it reads every rendered post
/// the document holds, those scrolled out of view included, with only the page's content text and link metadata (no
/// form value, nothing hidden by the page, no cookie or storage), within one explicit budget of posts, characters and
/// nodes. Posts are told apart by the site's ID or their link, so a feed that keeps the same number of nodes while it
/// replaces them (a virtualized list) still counts the new ones, and a post read again is not counted twice. A quoted
/// post stays in its card, apart from the post that quotes it.
///
/// It stops at the target; when several scrolls bring nothing new (`noProgress`), the page cannot scroll further
/// (`endOfPage`) or a read reached its budget (`readLimit`); at the deadline, which bounds every read and wait, or at
/// the scroll limit; at once on a page with nothing it can read (`unsupported`); and, keeping only what it read
/// before, when the session cannot go on or the page changed to another URL or document (`interrupted`). Before every
/// scroll, and after every await before anything read is kept, it asks `proceed`, the session's own checks.
@MainActor
struct WebPostCollector {

    /// Reads the page with `script`, waiting at most the seconds given.
    let read   : (_ timeout: Double) async throws -> JSONValue
    /// Scrolls the page down by about `pixels`, through the session's own traced scroll.
    let scroll : (_ pixels: Double) async throws -> Void
    /// The session's checks before an effect and after an await: its identity, profile, gate and cancellation.
    let proceed: () async throws -> Void
    let sleep  : (Duration) async throws -> Void
    let now    : () -> ContinuousClock.Instant

    /// Reads after a scroll before it counts as bringing nothing, and the wait before each.
    static let settleReads    = 6
    static let settleInterval = Duration.milliseconds(300)
    /// Scrolls in a row that bring nothing new before the collection stops.
    static let idleLimit      = 3
    /// The longest one read may take.
    static let readTimeout    = 10.0

    /// One read of the page.
    struct Read: Equatable {
        let site    : String
        let url     : String
        let document: Double
        let posts   : [CollectedPost]
        /// The budget the read reached, `posts`, `characters` or `nodes`: the page holds more than it took.
        let limit   : String?
        let atEnd   : Bool
        let viewport: Double
    }

    func collect(_ request: PostCollectionRequest) async throws -> PostCollection {
        let deadline = now() + .milliseconds(Int(request.seconds * 1000))
        func remaining() -> Double {
            let left = deadline - now()
            return Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
        }
        // The first read: nothing is kept unless the session is still the one it began in once it answered.
        let raw = try await read(min(Self.readTimeout, max(0.1, remaining())))
        try await proceed()
        let first = try Self.parse(raw, round: 0)
        var found: [String: Int] = [:]
        var posts: [CollectedPost] = []
        var reads = 1, scrolls = 0
        func merge(_ read: Read) -> Int {
            var gained = 0
            for post in read.posts {
                if let index = found[post.identity] {
                    // The same post read again: kept once, with the fuller text when this read shows more of it.
                    if post.textLength > posts[index].textLength {
                        posts[index] = post.firstFound(at: posts[index].round)
                    }
                } else {
                    found[post.identity] = posts.count
                    posts.append(post)
                    gained += 1
                }
            }
            return gained
        }
        func result(_ stop: PostCollectionStop, _ reason: String) -> PostCollection {
            PostCollection(pageURL: first.url, site: first.site, posts: Array(posts.prefix(request.target)),
                           stop: stop, reason: reason, target: request.target, scrolls: scrolls, reads: reads)
        }
        func shortfall() -> String { "\(posts.count) of \(request.target) posts: a partial answer, not padded." }
        _ = merge(first)
        guard first.site != "none" || !posts.isEmpty else {
            return result(.unsupported, "This page holds no post or article Braus can read: it reads X posts, Reddit "
                + "posts and pages built of <article> elements. Nothing was scrolled.")
        }
        var idle = 0
        var last = first
        while true {
            if posts.count >= request.target {
                let extra = posts.count - request.target
                return result(.targetReached, "Read \(request.target) distinct posts"
                    + (extra > 0 ? "; \(extra) more were on the page and are left out." : "."))
            }
            if remaining() <= 0 {
                return result(.deadline, "The \(Int(request.seconds)) seconds ran out: " + shortfall())
            }
            if scrolls >= request.maxScrolls {
                return result(.maxScrolls, "\(scrolls) scrolls, the limit, gave " + shortfall())
            }
            do {
                try await proceed()
                try await scroll(max(200, last.viewport * 0.85))
            } catch let error where !(error is CancellationError) {
                return result(.interrupted, "Stopped before scrolling again: \(error). The posts read before are "
                    + "kept; nothing more was sent.")
            }
            scrolls += 1
            var gained = 0
            for _ in 0..<Self.settleReads where gained == 0 && remaining() > 0 {
                let next: Read
                do {
                    try await sleep(min(Self.settleInterval, .milliseconds(Int(remaining() * 1000))))
                    try await proceed()
                    let raw = try await read(min(Self.readTimeout, max(0.1, remaining())))
                    // What a read answered is kept only from the session it began in.
                    try await proceed()
                    next = try Self.parse(raw, round: scrolls)
                } catch let error where !(error is CancellationError) {
                    if remaining() <= 0 {
                        return result(.deadline, "The \(Int(request.seconds)) seconds ran out: " + shortfall())
                    }
                    return result(.interrupted, "Stopped while reading after a scroll: \(error). The posts read "
                        + "before are kept.")
                }
                reads += 1
                guard next.url == first.url, next.document == first.document else {
                    return result(.interrupted, "The page changed during the collection, from \(first.url) to "
                        + "\(next.url): posts of the new page were not mixed in. The posts read before are kept.")
                }
                gained = merge(next)
                last = next
            }
            if gained > 0 {
                idle = 0
                continue
            }
            idle += 1
            if let limit = last.limit {
                return result(.readLimit, "The page holds more than one read takes (its \(limit) budget) and "
                    + "scrolling brought nothing new: " + shortfall())
            }
            if last.atEnd {
                return result(.endOfPage, "The page cannot scroll further and shows no new post: " + shortfall())
            }
            if idle >= Self.idleLimit {
                return result(.noProgress, "\(idle) scrolls in a row brought no new post: " + shortfall()
                    + " The page may need a sign-in or a click, or have no more.")
            }
        }
    }

    // MARK: Reading the script's answer

    /// The script's answer as a read; a post with no identity is dropped, since it could not be told apart.
    static func parse(_ value: JSONValue, round: Int) throws -> Read {
        guard let site = value["site"]?.stringValue, let url = value["url"]?.stringValue else {
            throw AutomationFailure("The page did not answer the post reader.")
        }
        let posts = (value["posts"]?.arrayValue ?? []).compactMap { row -> CollectedPost? in
            guard let identity = row["identity"]?.stringValue, !identity.isEmpty else { return nil }
            let quote = row["quote"].flatMap { quote -> CollectedQuote? in
                guard case .object = quote else { return nil }
                let text = quote["text"]?.stringValue ?? ""
                return CollectedQuote(author: quote["author"]?.stringValue, handle: quote["handle"]?.stringValue,
                                      text: text, textLength: quote["textLength"]?.intValue ?? text.count,
                                      truncated: quote["truncated"]?.boolValue ?? false, url: quote["url"]?.stringValue)
            }
            let text = row["text"]?.stringValue ?? ""
            return CollectedPost(
                identity       : identity,
                source         : row["source"]?.stringValue ?? site,
                author         : row["author"]?.stringValue,
                handle         : row["handle"]?.stringValue,
                text           : text,
                textLength     : row["textLength"]?.intValue ?? text.count,
                truncated      : row["truncated"]?.boolValue ?? false,
                shortenedBySite: row["shortenedBySite"]?.boolValue ?? false,
                url            : row["url"]?.stringValue,
                time           : row["time"]?.stringValue,
                context        : row["context"]?.stringValue,
                quote          : quote,
                fieldsClipped  : row["fieldsClipped"]?.boolValue ?? false,
                round          : round
            )
        }
        return Read(site: site, url: url, document: value["document"]?.doubleValue ?? 0, posts: posts,
                    limit: value["limit"]?.stringValue, atEnd: value["atEnd"]?.boolValue ?? false,
                    viewport: value["viewport"]?.doubleValue ?? 800)
    }

    // MARK: The script

    /// One read's budget: posts, characters of every text and field together, and element nodes visited.
    static let postLimit      = 400
    static let characterLimit = 600_000
    static let nodeLimit      = 300_000

    /// The reader the page runs: fixed, and bounded by `postLimit`, `characterLimit` and `nodeLimit`, saying which it
    /// reached; each text kept to `CollectedPost.textLimit` characters with its full length said, each field to
    /// `CollectedPost.fieldLimit` with the cut said. Only rendered content text and link metadata: no form control's
    /// value, nothing the page hides (display, visibility, aria-hidden, on the element or an ancestor), no cookie or
    /// storage. A post scrolled out of view is rendered, and read, also when `content-visibility: auto` skips it.
    static let script = """
        (() => {
          const TEXT = \(CollectedPost.textLimit), FIELD = \(CollectedPost.fieldLimit), MAX = \(postLimit);
          const CHARACTERS = \(characterLimit), NODES = \(nodeLimit);
          const host = location.hostname.replace(/^www\\./, "");
          const skipped = new Set(["INPUT", "TEXTAREA", "SELECT", "OPTION", "SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE",
                                   "BUTTON", "SVG", "CANVAS", "IFRAME"]);
          let nodes = 0, characters = 0, limit = null;
          const over = () => limit !== null;
          // Rendered: not hidden by display, visibility or content-visibility: hidden, nor aria-hidden, itself or by
          // an ancestor. Being out of view is not hidden, nor is content-visibility: auto skipping it off screen.
          const shownSelf = (element) => (!element.checkVisibility
              || element.checkVisibility({ visibilityProperty: true, contentVisibilityAuto: false }))
            && element.getAttribute("aria-hidden") !== "true";
          const shown = (element) => element !== null && shownSelf(element)
            && element.closest('[aria-hidden="true"]') === null;
          // An element's rendered text and its images' alt (emoji), never a control's value, never what `skip` keeps
          // apart (a quote card, a nested article); empty when the element itself is not rendered.
          const textOf = (root, skip) => {
            if (!shown(root)) return "";
            let out = "";
            const walk = (node) => {
              for (const child of node.childNodes) {
                if (over()) return;
                if (child.nodeType === 3) { out += child.nodeValue; continue; }
                if (child.nodeType !== 1) continue;
                if (++nodes > NODES) { limit = "nodes"; return; }
                const tag = child.tagName.toUpperCase();
                if (skipped.has(tag) || (skip && skip(child)) || !shownSelf(child)) continue;
                if (tag === "IMG") { out += child.getAttribute("alt") || ""; continue; }
                if (tag === "BR") { out += "\\n"; continue; }
                const block = /^(P|DIV|LI|H[1-6]|BLOCKQUOTE|PRE|SECTION|FIGCAPTION|TR)$/.test(tag);
                if (block) out += "\\n";
                walk(child);
                if (block) out += "\\n";
              }
            };
            walk(root);
            return out.replace(/[ \\t\\u00a0]+/g, " ").replace(/ *\\n */g, "\\n").replace(/\\n{3,}/g, "\\n\\n").trim();
          };
          let clipped = false;
          const field = (value) => {
            if (value === null || value === undefined || value === "") return null;
            const text = String(value);
            if (text.length > FIELD) { clipped = true; return text.slice(0, FIELD); }
            return text;
          };
          const clip = (text) => ({ text: text.length > TEXT ? text.slice(0, TEXT) : text, textLength: text.length,
                                    truncated: text.length > TEXT });
          const absolute = (href) => {
            try { return href ? new URL(href, location.href).href : null; } catch { return null; }
          };
          const posts = [];
          // Adds a post within the budget; false once a budget is reached, which ends the read.
          const push = (post) => {
            if (over()) return false;
            if (posts.length >= MAX) { limit = "posts"; return false; }
            const size = JSON.stringify(post).length;
            if (characters + size > CHARACTERS) { limit = "characters"; return false; }
            characters += size;
            posts.push(post);
            return true;
          };
          const post = (fields) => {
            clipped = false;
            const built = fields();
            built.fieldsClipped = clipped;
            return built;
          };
          let site = "none";

          if (host === "x.com" || host === "twitter.com" || host === "mobile.twitter.com") {
            site = "x";
            for (const article of document.querySelectorAll('article[data-testid="tweet"]')) {
              if (over()) break;
              if (!shown(article)) continue;
              // A quoted post sits in a card with its own author line: everything in it belongs to the quote.
              const names = article.querySelectorAll('[data-testid="User-Name"]');
              const card = names.length > 1 ? names[1].closest('div[role="link"]') : null;
              const inCard = (node) => card !== null && card.contains(node);
              const own = (selector) => Array.from(article.querySelectorAll(selector))
                .find((node) => !inCard(node)) || null;
              const parts = (node) => node ? textOf(node).split("\\n").map((part) => part.trim()).filter(Boolean) : [];
              const statusOf = (node) => {
                const link = node ? node.closest('a[href*="/status/"]') : null;
                const address = link ? absolute(link.getAttribute("href")) || "" : "";
                const match = address.match(/^https?:\\/\\/[^/]+\\/([^/]+)\\/status\\/(\\d+)/);
                return match ? { id: match[2], url: "https://x.com/" + match[1] + "/status/" + match[2] } : null;
              };
              const time = own("time[datetime]");
              const status = statusOf(time);
              if (!status) continue;
              const added = push(post(() => {
                const bodyNode = own('[data-testid="tweetText"]');
                const body = bodyNode ? textOf(bodyNode) : "";
                const author = parts(names[0] && !inCard(names[0]) ? names[0] : null);
                let quote = null;
                if (card && shown(card)) {
                  const quoted = parts(names[1]);
                  const quoteText = card.querySelector('[data-testid="tweetText"]');
                  const quoteStatus = statusOf(card.querySelector("time[datetime]"));
                  quote = { author: field(quoted[0]), handle: field(quoted.find((part) => part.startsWith("@"))),
                            ...clip(quoteText ? textOf(quoteText) : ""),
                            url: field(quoteStatus ? quoteStatus.url : null) };
                }
                const social = own('[data-testid="socialContext"]');
                return { identity: "x:" + status.id, source: "x", author: field(author[0]),
                         handle: field(author.find((part) => part.startsWith("@"))), ...clip(body),
                         shortenedBySite: own('[data-testid="tweet-text-show-more-link"]') !== null,
                         url: field(status.url), time: field(time.getAttribute("datetime")),
                         context: field(social ? textOf(social) : null), quote };
              }));
              if (!added) break;
            }
          } else if (host === "reddit.com" || host.endsWith(".reddit.com")) {
            site = "reddit";
            for (const item of document.querySelectorAll("shreddit-post")) {
              if (over()) break;
              if (!shown(item)) continue;
              const permalink = absolute(item.getAttribute("permalink"));
              const id = item.getAttribute("id") || permalink;
              if (!id) continue;
              const added = push(post(() => {
                const bodyNode = item.querySelector('[slot="text-body"]');
                const body = [item.getAttribute("post-title") || "", bodyNode ? textOf(bodyNode) : ""]
                  .filter(Boolean).join("\\n\\n");
                const author = item.getAttribute("author");
                return { identity: "reddit:" + id, source: "reddit", author: field(author),
                         handle: field(author ? "u/" + author : null), ...clip(body), shortenedBySite: false,
                         url: field(permalink), time: field(item.getAttribute("created-timestamp")),
                         context: field(item.getAttribute("subreddit-prefixed-name")), quote: null };
              }));
              if (!added) break;
            }
            for (const item of document.querySelectorAll('div.thing[data-fullname][data-type="link"]')) {
              if (over()) break;
              if (!shown(item)) continue;
              const added = push(post(() => {
                const title = item.querySelector("a.title");
                const bodyNode = item.querySelector(".usertext-body");
                const body = [title ? textOf(title) : "", bodyNode ? textOf(bodyNode) : ""]
                  .filter(Boolean).join("\\n\\n");
                const author = item.getAttribute("data-author");
                const stamp = Number(item.getAttribute("data-timestamp"));
                return { identity: "reddit:" + item.getAttribute("data-fullname"), source: "reddit",
                         author: field(author),
                         handle: field(author ? "u/" + author : null), ...clip(body), shortenedBySite: false,
                         url: field(absolute(item.getAttribute("data-permalink"))),
                         time: field(stamp ? new Date(stamp).toISOString() : null),
                         context: field(item.getAttribute("data-subreddit-prefixed")), quote: null };
              }));
              if (!added) break;
            }
          }

          if (site === "none") {
            // Articles that are not inside another: a nested one (a comment, a related card) stays out of the text.
            const articles = Array.from(document.querySelectorAll("article"))
              .filter((article) => !(article.parentElement && article.parentElement.closest("article")));
            if (articles.length > 0) site = "article";
            const canonical = document.querySelector('link[rel="canonical"]');
            for (const article of articles) {
              if (over()) break;
              if (!shown(article)) continue;
              const added = push(post(() => {
                const heading = article.querySelector("h1, h2, h3");
                const headingLink = heading ? (heading.querySelector("a[href]") || heading.closest("a[href]")) : null;
                const url = headingLink ? absolute(headingLink.getAttribute("href"))
                  : articles.length === 1
                    ? (canonical ? absolute(canonical.getAttribute("href")) : location.href)
                    : null;
                const authorNode = article.querySelector('[rel="author"], [itemprop="author"], .author, .byline');
                const time = article.querySelector("time[datetime]");
                const apart = new Set(["ARTICLE", "NAV", "ASIDE", "FORM", "FOOTER"]);
                const body = textOf(article, (node) => apart.has(node.tagName.toUpperCase()));
                const title = heading ? textOf(heading) : "";
                const identity = url ? "url:" + url : "article:" + title.slice(0, FIELD) + "|"
                  + (time ? time.getAttribute("datetime") : "") + "|" + body.slice(0, 200);
                return { identity, source: "article", author: field(authorNode ? textOf(authorNode) : null),
                         handle: null, ...clip(body), shortenedBySite: false, url: field(url),
                         time: field(time ? time.getAttribute("datetime") : null),
                         context: field(title), quote: null };
              }));
              if (!added) break;
            }
          }

          const scroller = document.scrollingElement || document.documentElement;
          return { site, url: location.href, document: performance.timeOrigin, posts, limit,
                   atEnd: scroller.scrollTop + innerHeight >= scroller.scrollHeight - 2, viewport: innerHeight };
        })()
        """
}

private extension CollectedPost {

    /// This post as first found in an earlier round.
    func firstFound(at round: Int) -> CollectedPost {
        CollectedPost(identity: identity, source: source, author: author, handle: handle, text: text,
                      textLength: textLength, truncated: truncated, shortenedBySite: shortenedBySite, url: url,
                      time: time, context: context, quote: quote, fieldsClipped: fieldsClipped, round: round)
    }
}

import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
#if BRAUS_PHASES
import PhaseSignposts
#endif

/// SceneTextPolicy owns the revisions and window baselines the model has read.
final class SceneTextPolicy {
    private(set) var revision = 0

    /// The last scene sent to the model of each window it read, most recent last: what the next scene
    /// of that window is sent as changes against.
    private(set) var seen: [Baseline] = []

    /// The session whose application a call may have changed behind the scene the model read (an adapter's verb, a
    /// held tool family's command): its baselines are dropped before its next scene, which is answered whole. Kept
    /// apart from `seen`, which a failed call puts back as it was.
    private var staleScene: UUID?

    /// Forgets every scene the model read, so the next scene of any window is sent whole: for a new
    /// turn or a compacted context, which may no longer hold those scenes.
    func forgetScene() {
        seen = []
    }

    /// The scene as the model reads it, which becomes its window's baseline. With `changesOnly`, a scene
    /// of a window the model already read is sent as its `changes` since that revision, when they are
    /// under half the scene's size: a diff any larger saves little and reads worse than the scene.
    /// `nested` is for an observation inside an action result, which already names the session and
    /// is the scene just after the action: it repeats neither the session nor the time.
    ///
    /// The text sent fits `SceneAnswerBudget`: a scene over it is sent as its outline and whole sections, the
    /// section an action aimed at (`aim`) kept first after any dialog, and changes over it are sent that way too.
    /// The baseline keeps the whole scene either way, so later changes and section reads stay exact.
    ///
    /// The scene's text and its changes are written on the concurrent pool. The revision and the baselines are read
    /// and updated together between those two waits, so a call that interleaves sees them either before or after.
    func observation(_ scene: SceneSnapshot, changesOnly: Bool = false, nested: Bool = false,
                     aim: (section: String?, target: String?) = (nil, nil),
                     session: any AutomationSessionOperating, shown: ValueMinimization) async -> JSONValue {
        #if BRAUS_PHASES
        let rendering = PhaseInterval.begin("render.scene")
        defer { rendering.end() }
        #endif
        let (scene, layout) = await Self.rendered(scene, minimizing: shown)
        let text = layout.text
        revision += 1
        let number = session.observedWindowNumber
        var values: [String: JSONValue] = ["revision": .number(Double(revision))]
        if !nested {
            values["session"]    = session.id.map { .string($0.uuidString) } ?? .null
            values["observedAt"] = .string(Date().ISO8601Format())
        }
        if let id = session.id, staleScene == id {
            seen.removeAll { $0.session == id }
            staleScene = nil
        }
        let known = session.id.flatMap { id in
            seen.lastIndex { $0.shows(scene, number: number, in: id) }
                ?? seen.lastIndex { $0.mayShow(scene, number: number, in: id) }
        }
        let baseline = known.map { seen[$0] }
        if let known { seen.remove(at: known) }
        if let id = session.id {
            seen.append(Baseline(session: id, windowNumber: number, revision: revision, scene: scene))
            if seen.count > Self.baselineLimit { seen.removeFirst() }
        }
        if changesOnly, let baseline {
            let changes = await Self.changes(from: baseline.scene, to: scene, since: baseline.revision)
            if changes.count * 2 < text.count, changes.count <= SceneAnswerBudget.characters {
                values["changes"] = .string(changes)
                values["since"] = .number(Double(baseline.revision))
            }
        }
        if values["changes"] == nil {
            values["scene"] = .string(SceneAnswerBudget.text(
                of   : layout,
                aimed: SceneAnswerBudget.aimedTitle(in: scene, section: aim.section, target: aim.target)
            ))
        }
        return .object(values)
    }

    /// Marks the scene of `session`'s application stale: its next scene is answered whole.
    func markSceneStale(of session: UUID?) {
        staleScene = session
    }

    /// One section of the latest scene `session` answered, read from its baseline: no new reading, so
    /// the revision and the baselines stay as they are and a later changes answer is still since that scene.
    func sectionReading(_ title: String, page: Int, session: UUID?) async throws -> JSONValue {
        guard let id = session, let baseline = seen.last(where: { $0.session == id }) else {
            throw AutomationFailure(ModelText.text(.init(rawValue: "scene_text_policy.unanswered.v1")))
        }
        guard staleScene != id else {
            throw AutomationFailure(ModelText.text(.init(rawValue: "scene_text_policy.stale.v1")))
        }
        let read = try await Self.section(title, page: page, of: baseline.scene)
        var values: [String: JSONValue] = [
            "revision": .number(Double(baseline.revision)), "session": .string(id.uuidString),
            "section" : .string(read.title), "scene": .string(read.text)
        ]
        if read.pages > 1 {
            values["page"]  = .number(Double(page))
            values["pages"] = .number(Double(read.pages))
        }
        return .object(values)
    }

    @concurrent
    private static func section(_ title: String, page: Int,
                                of scene: SceneSnapshot) async throws -> (title: String, text: String, pages: Int) {
        try SceneAnswerBudget.section(title, page: page, of: scene, layout: scene.textLayout())
    }

    /// The scene as it is shown and its text. The producer's secrets and what the call withholds are withheld from
    /// the scene's elements before the scene is written as text, where a value is quoted and escaped.
    @concurrent
    private static func rendered(
        _ scene         : SceneSnapshot,
        minimizing shown: ValueMinimization
    ) async -> (scene: SceneSnapshot, layout: SceneTextLayout) {
        let scene = shown.knowsNoText ? scene : shown.minimize(scene: scene)
        return (scene, scene.textLayout())
    }

    @concurrent
    private static func changes(from before: SceneSnapshot, to after: SceneSnapshot, since revision: Int) async -> String {
        SceneChanges.text(from: before, to: after, since: revision)
    }

    /// The most windows whose last scene is kept, the least recently read forgotten first: a turn
    /// moves between a window and its dialogs, rarely across more.
    private static let baselineLimit = 8

    /// One scene the model read, of one window, and the revision it was sent as.
    struct Baseline {
        let session: UUID
        /// The window server's number for the window, when the session knew it.
        let windowNumber: Int?
        let revision: Int
        let scene: SceneSnapshot

        /// True when `scene`, read in `session` from window `number`, shows this baseline's window:
        /// the same window number when both are known, else the same application and title.
        func shows(_ scene: SceneSnapshot, number: Int?, in session: UUID) -> Bool {
            guard session == self.session, scene.bundleID == self.scene.bundleID else { return false }
            if let number, let windowNumber { return number == windowNumber }
            return scene.windowTitle == self.scene.windowTitle
        }

        /// True when `scene` may be this baseline's window having lost or gained its title, which
        /// keeps its size: asked only when no baseline `shows` the scene, and never across two numbers.
        func mayShow(_ scene: SceneSnapshot, number: Int?, in session: UUID) -> Bool {
            guard session == self.session, scene.bundleID == self.scene.bundleID,
                  number == nil || windowNumber == nil else { return false }
            return (scene.windowTitle.isEmpty || self.scene.windowTitle.isEmpty)
                && scene.viewportPixelSize == self.scene.viewportPixelSize
        }
    }

    func keepBaseline(_ before: [Baseline]) {
        seen = before
    }
}

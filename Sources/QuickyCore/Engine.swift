import Foundation
import Observation

/// The interpreter. Holds the one `Session`, routes each `Effect` to the runner that owns its resource,
/// feeds results back as `Completion`s, and publishes `scene`. `send` does no I/O.
@MainActor @Observable
public final class Engine {
    public private(set) var scene: PanelScene = .hidden
    @ObservationIgnored public var onNotice: (@MainActor (Notice) -> Void)?
    @ObservationIgnored public var onTrace: (@MainActor (Notice) -> Void)?
    @ObservationIgnored private let chatRun: ChatRun
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let noticeLog: NoticeLog?
    @ObservationIgnored private var session: Session
    @ObservationIgnored private var tasks: [EffectID: Task<Void, Never>] = [:]
    @ObservationIgnored private var runs: [EffectID: String?] = [:]
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private let fixedWall: Date?
    @ObservationIgnored private var turnStarted: [String: Double] = [:]
    @ObservationIgnored private var firstToken: [String: Double] = [:]

    public init(device: any Device, config: Config, storeDirectory: URL) {
        self.chatRun = ChatRun(config: config)
        self.store = Store(directory: storeDirectory)
        self.noticeLog = nil
        self.session = Session(chatModel: config.chatModel, deviceName: "mac")
        self.fixedWall = nil
    }

    public init(device: any Device, config: Config, storeDirectory: URL, chats: ChatLog, storeRevision: Int = 0, logURL: URL? = nil, fixedWall: Date? = nil, deviceName: String = "fixture") {
        self.chatRun = ChatRun(config: config)
        self.store = Store(directory: storeDirectory)
        self.noticeLog = logURL.map(NoticeLog.init)
        self.session = Session(chats: chats, chatModel: config.chatModel, revision: storeRevision, deviceName: deviceName)
        self.fixedWall = fixedWall
        self.scene = PanelScene(session: session)
    }

    @discardableResult
    public func send(_ input: Input, run: String? = nil) -> Disposition {
        let now = currentNow
        return apply(session.handle(.input(input), at: now), at: now, run: run)
    }

    @discardableResult
    public func send(_ input: Input, at now: Now, run: String? = nil) -> Disposition {
        apply(session.handle(.input(input), at: now), at: now, run: run)
    }

    private func apply(_ reaction: Reaction, at now: Now, run: String?) -> Disposition {
        scene = PanelScene(session: session)
        for raw in reaction.notices { publish(enrich(raw, run: run, now: now)) }
        for effect in reaction.effects { dispatch(effect, run: run) }
        scheduleTick(from: now)
        return reaction.disposition
    }

    private func dispatch(_ effect: Effect, run: String?) {
        trace("effect", effectID: effect.id, detail: effect.description, run: run)
        switch effect {
        case let .chat(id, request):
            runs[id] = run
            tasks[id] = Task { [chatRun, engine = self] in
                await chatRun.run(request, id: id) { completion in await engine.receive(completion) }
            }
        case let .reloadKeys(id):
            runs[id] = run
            tasks[id] = Task { [chatRun, weak self] in await chatRun.reload(); self?.receive(.keysReloaded(id)) }
        case let .cancel(id):
            tasks[id]?.cancel()
        case let .persist(id, state):
            runs[id] = run
            tasks[id] = Task { [store, weak self] in
                do { _ = try await store.write(state); await self?.receive(.persisted(id, revision: state.revision)) }
                catch { await self?.receive(.failed(id, .transport("Persistence failed"))) }
            }
        }
    }

    private func receive(_ completion: Completion) {
        let id = completion.id
        guard tasks[id] != nil else { return }
        let run = runs[id] ?? nil
        trace("completion", effectID: id, detail: completion.description, run: run)
        if completion.isTerminal { tasks[id] = nil; runs[id] = nil }
        let now = currentNow
        _ = apply(session.handle(.completion(completion), at: now), at: now, run: run)
    }

    private func scheduleTick(from now: Now) {
        tickTask?.cancel(); guard let deadline = session.nextDeadline else { return }
        let delay = max(0, deadline - now.monotonicMS)
        tickTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay)); guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    private func tick() {
        let now = currentNow
        _ = apply(session.handle(.tick, at: now), at: now, run: nil)
    }

    private func publish(_ notice: Notice) {
        onNotice?(notice)
        if let noticeLog { Task { await noticeLog.append(notice) } }
    }

    private func enrich(_ raw: Notice, run: String?, now: Now) -> Notice {
        var fields = raw.fields
        if raw.type == "turn", case let .string(id) = fields["turn"] { turnStarted[id] = now.monotonicMS }
        if raw.type == "token", case let .string(id) = fields["turn"], firstToken[id] == nil { firstToken[id] = now.monotonicMS }
        if raw.type == "done", case let .string(id) = fields["turn"], let start = turnStarted[id] {
            fields["ttft_ms"] = .int(Int(max(0, (firstToken[id] ?? now.monotonicMS) - start)))
            fields["total_ms"] = .int(Int(max(0, now.monotonicMS - start)))
            turnStarted[id] = nil; firstToken[id] = nil
        }
        return Notice(run: run ?? raw.run, type: raw.type, fields: fields)
    }

    private func trace(_ kind: String, effectID: EffectID, detail: String, run: String?) {
        onTrace?(Notice(run: run, type: "trace", fields: ["kind": .string(kind), "effect": .string(effectID.rawValue), "detail": .string(detail)]))
    }

    private var currentNow: Now { Now(monotonicMS: ProcessInfo.processInfo.systemUptime * 1000, wall: fixedWall ?? Date()) }
}

private extension Effect {
    var id: EffectID { switch self { case let .chat(id, _), let .reloadKeys(id), let .cancel(id), let .persist(id, _): id } }
    var description: String {
        switch self {
        case let .chat(_, request):
            let body = (try? JSONEncoder.stable.encode(request)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return "chat \(request.version) body=\(body)"
        case .reloadKeys: return "reloadKeys"
        case .cancel: return "cancel"
        case let .persist(_, state): return "persist revision=\(state.revision)"
        }
    }
}

private extension Completion {
    var id: EffectID { switch self { case let .token(id, _), let .ended(id), let .failed(id, _), let .unauthorized(id), let .keysReloaded(id), let .cancelled(id), let .persisted(id, _): id } }
    var isTerminal: Bool { switch self { case .token: false; default: true } }
    var description: String { switch self { case let .token(_, text): "token chars=\(text.count)"; case .ended: "ended"; case .failed: "failed"; case .unauthorized: "unauthorized"; case .keysReloaded: "keysReloaded"; case .cancelled: "cancelled"; case let .persisted(_, revision): "persisted revision=\(revision)" } }
}

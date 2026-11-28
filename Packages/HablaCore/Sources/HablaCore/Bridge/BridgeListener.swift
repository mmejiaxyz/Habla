import Foundation
import Network

/// Keeps one live connection to the account (`GET /v2/listen`, a hibernating WebSocket: idle costs
/// nothing) and calls `onChange` the moment something changes for this device. While it is
/// connected, this device counts as running for the others. Reconnects after sleep, network
/// changes and errors (backing off up to 5 minutes); pings are protocol pings, which are free.
public final class BridgeListener: NSObject, @unchecked Sendable, URLSessionWebSocketDelegate {
    let request: URLRequest
    let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var running = false
    private var backoff: TimeInterval = 2
    private var generation = 0
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "habla.bridge.listen")

    public init(config: BridgeConfig, deviceID: String, onChange: @escaping @Sendable () -> Void) {
        let keys = BridgeKeys(libraryKey: config.libraryKey)
        var c = URLComponents(url: config.url.appendingPathComponent("v2/listen"), resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(keys.token)", forHTTPHeaderField: "Authorization")
        r.setValue(keys.objectName("device/\(deviceID)"), forHTTPHeaderField: "X-Habla-Device")
        request = r
        self.onChange = onChange
    }

    public func start() {
        lock.withLock { running = true }
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { self?.reconnect(now: true) }      // new network: reconnect at once
        }
        monitor.start(queue: queue)
        reconnect(now: true)
    }

    public func stop() {
        lock.withLock { running = false; generation += 1 }
        monitor.cancel()
        task?.cancel(with: .goingAway, reason: nil)
    }

    /// After the Mac wakes: the old connection is dead; open a fresh one now.
    public func reconnect(now: Bool = false) {
        let gen: Int? = lock.withLock {
            guard running else { return nil }
            generation += 1
            if now { backoff = 2 }
            return generation
        }
        guard let gen else { return }
        task?.cancel(with: .goingAway, reason: nil)
        let delay = now ? 0 : lock.withLock { backoff }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.open(gen) }
    }

    private func open(_ gen: Int) {
        guard lock.withLock({ running && gen == generation }) else { return }
        let s = session ?? URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        let t = s.webSocketTask(with: request)
        lock.withLock { task = t }
        t.resume()
        receive(t, gen)
        ping(t, gen)
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            guard let self, self.lock.withLock({ gen == self.generation }) else { return }
            switch result {
            case .success:
                self.lock.withLock { self.backoff = 2 }
                self.onChange()
                self.receive(t, gen)
            case .failure:
                self.retry(gen)
            }
        }
    }

    /// A protocol ping every 50 s keeps routers from dropping the idle connection.
    private func ping(_ t: URLSessionWebSocketTask, _ gen: Int) {
        queue.asyncAfter(deadline: .now() + 50) { [weak self] in
            guard let self, self.lock.withLock({ gen == self.generation && self.running }) else { return }
            t.sendPing { error in
                if error != nil { self.retry(gen) } else { self.ping(t, gen) }
            }
        }
    }

    private func retry(_ gen: Int) {
        let go: Bool = lock.withLock {
            guard gen == generation, running else { return false }
            backoff = min(backoff * 2, 300)
            return true
        }
        if go { reconnect() }
    }

    /// Connected (again): catch up on anything missed while away.
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onChange()
    }
}

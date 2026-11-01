import Foundation

/// Coalesce notification bursts into one scan and one fresh follow-up. Never
/// publish a snapshot requested before a later mount/unmount notification.
@MainActor
final class SnapshotRefreshCoordinator<Value: Sendable> {
    private let load: () async throws -> Value
    private let apply: (Result<Value, Error>) -> Void
    private var revision = 0
    private var worker: Task<Void, Never>?

    init(load: @escaping () async throws -> Value, apply: @escaping (Result<Value, Error>) -> Void) {
        self.load = load
        self.apply = apply
    }

    func request() {
        revision += 1
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let request = revision
                let result: Result<Value, Error>
                do { result = .success(try await load()) }
                catch { result = .failure(error) }
                if request != revision { continue }
                worker = nil
                apply(result)
                return
            }
            worker = nil
        }
    }
}

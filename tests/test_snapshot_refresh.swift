import Foundation

@main @MainActor struct SnapshotRefreshRegression {
    static func main() async {
        var pending: [CheckedContinuation<[Int], Error>] = []
        var snapshots: [[Int]] = []
        var failures = 0
        let refresh = SnapshotRefreshCoordinator<[Int]>(load: {
            try await withCheckedThrowingContinuation { pending.append($0) }
        }, apply: {
            switch $0 {
            case .success(let value): snapshots.append(value)
            case .failure: failures += 1
            }
        })
        refresh.request()
        await wait { pending.count == 1 }
        for _ in 0..<50 { refresh.request() }
        precondition(pending.count == 1)
        pending[0].resume(returning: [1])
        await wait { pending.count == 2 }
        precondition(snapshots.isEmpty, "A snapshot older than an unmount notification was published")
        pending[1].resume(returning: [2])
        await wait { snapshots.count == 1 }
        precondition(snapshots == [[2]])
        refresh.request()
        await wait { pending.count == 3 }
        pending[2].resume(throwing: POSIXError(.EIO))
        await wait { failures == 1 }
        precondition(snapshots == [[2]], "Scan errors must not look like an empty successful scan")
        refresh.request()
        await wait { pending.count == 4 }
        pending[3].resume(returning: [])
        await wait { snapshots.count == 2 }
        precondition(snapshots == [[2], []])

        var calls = 0, applied = 0
        var reentrant: SnapshotRefreshCoordinator<Int>?
        reentrant = SnapshotRefreshCoordinator(load: { calls += 1; return calls }, apply: { _ in
            applied += 1
            if applied == 1 { reentrant?.request() }
        })
        reentrant?.request()
        await wait { applied == 2 }
        precondition(calls == 2)
        reentrant = nil
        print("Snapshot tests passed (50 requests coalesced, stale snapshot discarded, failure vs empty, recovery, reentrant refresh)")
    }

    static func wait(_ ready: () -> Bool) async {
        for _ in 0..<10000 { if ready() { return }; await Task.yield() }
        preconditionFailure("Snapshot worker did not progress")
    }
}

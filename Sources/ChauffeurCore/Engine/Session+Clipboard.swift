import Foundation

/// The simulator pasteboard reduced to what may leave the daemon (M4b spec §7): a hash to compare, and a length.
struct ClipboardMark: Equatable, Sendable, CustomStringConvertible {
    let hash: Int
    let characters: Int

    init(_ text: String) {
        hash = text.hashValue
        characters = text.count
    }

    var description: String { "clipboard (\(characters) characters)" }

    /// What a tap copied: the new length, when the pasteboard changed to something non-empty.
    static func copied(before: ClipboardMark?, after: ClipboardMark?) -> Int? {
        guard let before, let after, after != before, after.characters > 0 else { return nil }
        return after.characters
    }
}

/// Work started on a background queue and collected later, so a slow read (`pbpaste`, ~100 ms) overlaps the baseline.
final class Background<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private let done = DispatchSemaphore(value: 0)

    init(_ work: @escaping @Sendable () -> T) {
        DispatchQueue.global(qos: .userInitiated).async {
            let v = work()
            self.lock.withLock { self.value = v }
            self.done.signal()
        }
    }

    /// The result, waiting at most `ms`; nil if it isn't ready by then.
    func result(waitingAtMost ms: Int) -> T? {
        if done.wait(timeout: .now() + .milliseconds(ms)) == .success { done.signal() }
        return lock.withLock { value }
    }
}

extension Session {
    nonisolated static func readClipboard(udid: String, shell: any ShellRunner) -> ClipboardMark? {
        guard let r = try? shell.simctl(["pbpaste", udid], timeout: 5), r.status == 0 else { return nil }
        return ClipboardMark(r.out)
    }
}

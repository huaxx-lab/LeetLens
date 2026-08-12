import Darwin
import Foundation

struct SubprocessResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

enum SubprocessRunnerError: LocalizedError {
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            "辅助进程在 \(Int(seconds.rounded())) 秒内没有响应"
        }
    }
}

enum SubprocessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: Data? = nil,
        timeout: TimeInterval
    ) async throws -> SubprocessResult {
        let execution = SubprocessExecution(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            timeout: timeout
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class SubprocessExecution: @unchecked Sendable {
    private let process = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let inputData: Data?
    private let timeout: TimeInterval
    private let lock = NSLock()
    private let drainQueue = DispatchQueue(label: "leetcode.subprocess.drain", qos: .utility)
    private var standardOutput = Data()
    private var standardError = Data()
    private var continuation: CheckedContinuation<SubprocessResult, Error>?
    private var didComplete = false
    private var isCancelled = false

    /// Grace between `SIGTERM` and `SIGKILL`.
    private static let killGracePeriod: TimeInterval = 0.25

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        standardInput: Data?,
        timeout: TimeInterval
    ) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        inputData = standardInput
        self.timeout = timeout
        if standardInput != nil { process.standardInput = Pipe() }
    }

    func start(_ continuation: CheckedContinuation<SubprocessResult, Error>) {
        // `withTaskCancellationHandler` can run `cancel()` before this body, so
        // registering the continuation and observing an earlier cancellation must be
        // one atomic step. Splitting them is what used to strand the continuation.
        let wasCancelledBeforeStart: Bool = lock.withLock {
            guard !isCancelled else { return true }
            self.continuation = continuation
            return false
        }
        guard !wasCancelledBeforeStart else {
            // Never launch work the caller has already abandoned.
            continuation.resume(throwing: CancellationError())
            return
        }

        installDrainHandlers()
        process.terminationHandler = { [weak self] process in
            self?.finishAfterDraining(status: process.terminationStatus)
        }

        // A cancellation can land between arming and launching; if it already
        // resumed the continuation there is nothing left to run.
        guard lock.withLock({ !didComplete }) else { return }

        do {
            try process.run()
        } catch {
            complete(.failure(error))
            return
        }
        writeInput()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.timeOutIfNeeded()
        }
        // Cancellation that raced the launch still has to reap the child.
        if lock.withLock({ isCancelled }) { terminateProcessTree() }
    }

    func cancel() {
        lock.withLock { isCancelled = true }
        // Resuming unblocks the caller; terminating stops the child. Neither step
        // may be skipped because the other already happened.
        complete(.failure(CancellationError()))
        terminateProcessTree()
    }

    private func installDrainHandlers() {
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.lock.withLock { self?.standardOutput.append(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.lock.withLock { self?.standardError.append(data) }
        }
    }

    private func writeInput() {
        guard let inputData, let inputPipe = process.standardInput as? Pipe else { return }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: inputData)
            try inputPipe.fileHandleForWriting.close()
        } catch {
            if complete(.failure(error)) { terminateProcessTree() }
        }
    }

    private func finishAfterDraining(status: Int32) {
        drainQueue.async { [weak self] in
            guard let self else { return }
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            if let tail = try? outputPipe.fileHandleForReading.readToEnd() { lock.withLock { standardOutput.append(tail) } }
            if let tail = try? errorPipe.fileHandleForReading.readToEnd() { lock.withLock { standardError.append(tail) } }
            let result = lock.withLock {
                SubprocessResult(
                    terminationStatus: status,
                    standardOutput: standardOutput,
                    standardError: standardError
                )
            }
            complete(.success(result))
        }
    }

    private func timeOutIfNeeded() {
        // Reserve completion before signalling the child. Otherwise the termination
        // handler can win the race and turn a timeout into an apparent success.
        guard complete(.failure(SubprocessRunnerError.timedOut(timeout))) else { return }
        terminateProcessTree()
    }

    /// Stops the child on both the timeout and the cancellation path.
    ///
    /// A child that ignores or is slow to handle `SIGTERM` used to survive
    /// cancellation indefinitely, so termination always escalates to `SIGKILL`.
    /// The negative-PID signals are best effort: they only match when the child made
    /// itself a process-group leader, in which case they take its descendants too.
    private func terminateProcessTree() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }

        process.terminate()
        Darwin.kill(-pid, SIGTERM)

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.killGracePeriod) { [process] in
            guard process.isRunning else { return }
            Darwin.kill(pid, SIGKILL)
            Darwin.kill(-pid, SIGKILL)
        }
    }

    @discardableResult
    private func complete(_ result: Result<SubprocessResult, Error>) -> Bool {
        let pending = lock.withLock { () -> CheckedContinuation<SubprocessResult, Error>? in
            // Only a real continuation may consume completion. Marking the execution
            // finished while none is installed is what made a pre-cancelled call hang
            // forever once `start` finally arrived.
            guard !didComplete, let value = continuation else { return nil }
            didComplete = true
            continuation = nil
            return value
        }
        guard let pending else { return false }
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        pending.resume(with: result)
        return true
    }
}

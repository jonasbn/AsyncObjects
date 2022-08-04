import Foundation

/// An object that eventually produces a single value and then finishes or fails.
///
/// Use a future to perform some work and then asynchronously publish a single element.
/// You can initialize the future with a closure that takes a ``Future/Promise``;
/// the closure calls the promise with a `Result` that indicates either success or failure.
/// 
/// Otherwise, you can create future and fulfill it with a `Result` that indicates either success or failure
/// by using ``fulfill(with:)`` method. In the success case,
/// the future’s downstream subscriber receives the element prior to the publishing stream finishing normally.
/// If the result is an error, publishing terminates with that error.
public actor Future<Output, Failure: Error> {
    /// A type that represents a closure to invoke in the future, when an element or error is available.
    ///
    /// The promise closure receives one parameter: a `Result` that contains
    /// either a single element published by a ``Future``, or an error.
    public typealias Promise = (FutureResult) -> Void
    /// A type that represents the result in the future, when an element or error is available.
    public typealias FutureResult = Result<Output, Failure>
    /// The suspended tasks continuation type.
    private typealias Continuation = GlobalContinuation<Output, Failure>
    /// The underlying value that future is fulfilled with.
    private var wrappedValue: FutureResult?
    /// The continuations stored with an associated key for all the suspended task
    /// that are waiting for future to be fulfilled.
    private var continuations: [UUID: Continuation] = [:]

    /// Add continuation with the provided key in `continuations` map.
    ///
    /// - Parameters:
    ///   - continuation: The `continuation` to add.
    ///   - key: The key in the map.
    @inline(__always)
    private func addContinuation(
        _ continuation: Continuation,
        withKey key: UUID = .init()
    ) {
        continuations[key] = continuation
    }

    /// Creates a future that can be fulfilled later by ``fulfill(with:)`` or
    /// any other variation of this methos.
    ///
    /// - Returns: The newly created future.
    public init() { }

    /// Create an already fulfilled promise with the provided `Result`.
    ///
    /// - Parameter result: The result of the future.
    ///
    /// - Returns: The newly created future.
    public init(with result: FutureResult) async {
        self.fulfill(with: result)
    }

    /// Creates a future that invokes a promise closure when the publisher emits an element.
    ///
    /// - Parameters:
    ///   - attemptToFulfill: A ``Future/Promise`` that the publisher invokes
    ///                       when the publisher emits an element or terminates with an error.
    ///
    /// - Returns: The newly created future.
    public init(
        attemptToFulfill: @escaping (
            @escaping Future<Output, Failure>.Promise
        ) async -> Void
    ) async {
        Task { await attemptToFulfill(self.fulfill(with:)) }
    }

    deinit {
        guard Failure.self is Error.Protocol else { return }
        (continuations as! [UUID: GlobalContinuation<Output, Error>])
            .forEach { $0.value.cancel() }
    }

    /// Fulfill the future by producing the given value and notify subscribers.
    ///
    /// A future must be fulfilled exactly once. If the future has already been fulfilled,
    /// then calling this method has no effect and returns immediately.
    ///
    /// - Parameter value: The value to produce from the future.
    public func fulfill(producing value: Output) {
        self.fulfill(with: .success(value))
    }

    /// Terminate the future with the given error and propagate error to subscribers.
    ///
    /// A future must be fulfilled exactly once. If the future has already been fulfilled,
    /// then calling this method has no effect and returns immediately.
    ///
    /// - Parameter error: The error to throw to the callers.
    public func fulfill(throwing error: Failure) {
        self.fulfill(with: .failure(error))
    }

    /// Fulfill the future by returning or throwing the given result value.
    ///
    /// A future must be fulfilled exactly once. If the future has already been fulfilled,
    /// then calling this method has no effect and returns immediately.
    ///
    /// - Parameter result: The result. If it contains a `.success` value,
    ///                     that value delivered asynchronously to callers;
    ///                     otherwise, the awaiting caller receives the `.error` instead.
    public func fulfill(with result: FutureResult) {
        wrappedValue = result
        continuations.forEach { $0.value.resume(with: result) }
        continuations = [:]
    }
}

// MARK: Non-Throwing Future
extension Future where Failure == Never {
    /// The published value of the future, delivered asynchronously.
    ///
    /// This property exposes the fulfilled value for the `Future` asynchronously.
    /// Immidiately returns if `Future` is fulfilled otherwise waits asynchronously
    /// for `Future` to be fulfilled.
    public var value: Output {
        get async {
            if let value = wrappedValue { return try! value.get() }
            return await Continuation.with { self.addContinuation($0) }
        }
    }

    /// Combines into a single future, for all futures to be fulfilled.
    ///
    /// If the returned future fulfills, it is fulfilled with an aggregating array of the values from the fulfilled futures,
    /// in the same order as provided.
    ///
    /// - Parameter futures: The futures to combine.
    ///
    /// - Returns: Already fulfilled future if no future provided, or a pending future
    ///            combining provided futures.
    public static func all(
        _ futures: [Future<Output, Failure>]
    ) async -> Future<[Output], Failure> {
        typealias IndexedOutput = (index: Int, value: Output)
        guard !futures.isEmpty else { return await .init(with: .success([])) }
        return await .init { promise in
            await withTaskGroup(of: IndexedOutput.self) { group in
                var result: [IndexedOutput] = []
                result.reserveCapacity(futures.count)
                for (index, future) in futures.enumerated() {
                    group.addTask { (index: index, value: await future.value) }
                }
                for await item in group { result.append(item) }
                promise(
                    .success(
                        result.sorted { $0.index < $1.index }.map(\.value)
                    )
                )
            }
        }
    }

    /// Combines into a single future, for all futures to be fulfilled.
    ///
    /// If the returned future fulfills, it is fulfilled with an aggregating array of the values from the fulfilled futures,
    /// in the same order as provided.
    ///
    /// - Parameter futures: The futures to combine.
    ///
    /// - Returns: Already fulfilled future if no future provided, or a pending future
    ///            combining provided futures.
    public static func all(
        _ futures: Future<Output, Failure>...
    ) async -> Future<[Output], Failure> {
        return await Self.all(futures)
    }

    /// Combines into a single future, for all futures to have settled.
    ///
    /// Returns a future that fulfills after all of the given futures is fulfilled,
    /// with an array of `Result`s that each describe the outcome of each future
    /// in the same order as provided.
    ///
    /// - Parameter futures: The futures to combine.
    ///
    /// - Returns: Already fulfilled future if no future provided, or a pending future
    ///            combining provided futures.
    public static func allSettled(
        _ futures: [Future<Output, Failure>]
    ) async -> Future<[FutureResult], Never> {
        typealias IndexedOutput = (index: Int, value: FutureResult)
        guard !futures.isEmpty else { return await .init(with: .success([])) }
        return await .init { promise in
            await withTaskGroup(of: IndexedOutput.self) { group in
                var result: [IndexedOutput] = []
                result.reserveCapacity(futures.count)
                for (index, future) in futures.enumerated() {
                    group.addTask {
                        (index: index, value: .success(await future.value))
                    }
                }
                for await item in group { result.append(item) }
                promise(
                    .success(
                        result.sorted { $0.index < $1.index }.map(\.value)
                    )
                )
            }
        }
    }

    /// Combines into a single future, for all futures to have settled.
    ///
    /// Returns a future that fulfills after all of the given futures is fulfilled,
    /// with an array of `Result`s that each describe the outcome of each future
    /// in the same order as provided.
    ///
    /// - Parameter futures: The futures to combine.
    ///
    /// - Returns: Already fulfilled future if no future provided, or a pending future
    ///            combining provided futures.
    public static func allSettled(
        _ futures: Future<Output, Failure>...
    ) async -> Future<[FutureResult], Never> {
        return await Self.allSettled(futures)
    }

    /// Takes multiple futures and, returns a single future that fulfills with the value
    /// as soon as any of the futures is fulfilled.
    ///
    /// If the returned future fulfills, it is fulfilled with the value of the first future that fulfilled.
    ///
    /// - Parameter futures: The futures to combine.
    ///
    /// - Returns: A pending future combining provided futures, or a forever pending future
    ///            if no future provided.
    public static func race(
        _ futures: [Future<Output, Failure>]
    ) async -> Future<Output, Failure> {
        return await .init { promise in
            await withTaskGroup(of: Output.self) { group in
                futures.forEach { future in
                    group.addTask { await future.value }
                }
                if let first = await group.next() {
                    promise(.success(first))
                }
            }
        }
    }

    /// Takes multiple futures and, returns a single future that fulfills with the value
    /// as soon as any of the futures is fulfilled.
    ///
    /// If the returned future fulfills, it is fulfilled with the value of the first future that fulfilled.
    ///
    /// - Parameter futures: The futures to combine.
    ///
    /// - Returns: A pending future combining provided futures, or a forever pending future
    ///            if no future provided.
    public static func race(
        _ futures: Future<Output, Failure>...
    ) async -> Future<Output, Failure> {
        return await Self.race(futures)
    }

    /// Takes multiple futures and, returns a single future that fulfills with the value as soon as one of the futures fulfills.
    ///
    /// If the returned future fulfills, it is fulfilled with the value of the first future that fulfilled.
    ///
    /// - Parameter futures: The futures to wait for.
    ///
    /// - Returns: A pending future waiting for first fulfilled future from provided futures,
    ///            or a forever pending future if no future provided.
    public static func any(
        _ futures: [Future<Output, Failure>]
    ) async -> Future<Output, Failure> {
        return await Self.race(futures)
    }

    /// Takes multiple futures and, returns a single future that fulfills with the value as soon as one of the futures fulfills.
    ///
    /// If the returned future fulfills, it is fulfilled with the value of the first future that fulfilled.
    ///
    /// - Parameter futures: The futures to wait for.
    ///
    /// - Returns: A pending future waiting for first fulfilled future from provided futures,
    ///            or a forever pending future if no future provided.
    public static func any(
        _ futures: Future<Output, Failure>...
    ) async -> Future<Output, Failure> {
        return await Self.any(futures)
    }
}

// MARK: Throwing Future
extension Future where Failure == Error {
    /// Remove continuation associated with provided key
    /// from `continuations` map and resumes with `CancellationError`.
    ///
    /// - Parameter key: The key in the map.
    @inline(__always)
    private func removeContinuation(withKey key: UUID) {
        let continuation = continuations.removeValue(forKey: key)
        continuation?.resume(throwing: CancellationError())
    }

    /// Suspends the current task, then calls the given closure with a throwing continuation for the current task.
    /// Continuation can be cancelled with error if current task is cancelled, by invoking `removeContinuation`.
    ///
    /// Spins up a new continuation and requests to track it with key by invoking `addContinuation`.
    /// This operation cooperatively checks for cancellation and reacting to it by invoking `removeContinuation`.
    /// Continuation can be resumed with error and some cleanup code can be run here.
    ///
    /// - Returns: The value continuation is resumed with.
    ///
    /// - Throws: If `resume(throwing:)` is called on the continuation, this function throws that error.
    @inline(__always)
    private func withPromisedContinuation() async throws -> Output {
        let key = UUID()
        let value = try await withTaskCancellationHandler { [weak self] in
            Task { [weak self] in
                await self?.removeContinuation(withKey: key)
            }
        } operation: { () -> Continuation.Success in
            let value = try await Continuation.with { continuation in
                self.addContinuation(continuation, withKey: key)
            }
            return value
        }
        return value
    }

    /// The published value of the future or an error, delivered asynchronously.
    ///
    /// This property exposes the fulfilled value for the `Future` asynchronously.
    /// Immidiately returns if `Future` is fulfilled otherwise waits asynchronously
    /// for `Future` to be fulfilled. If the Future terminates with an error,
    /// the awaiting caller receives the error instead.
    public var value: Output {
        get async throws {
            if let value = wrappedValue { return try value.get() }
            return try await withPromisedContinuation()
        }
    }

    /// Combines into a single future, for all futures to be fulfilled, or for any to be rejected.
    ///
    /// If the returned future fulfills, it is fulfilled with an aggregating array of the values from the fulfilled futures,
    /// in the same order as provided.
    ///
    /// If it rejects, it is rejected with the error from the first future that was rejected.
    ///
    /// - Parameter futures: The futures to combine.
    ///
    /// - Returns: Already fulfilled future if no future provided, or a pending future
    ///            combining provided futures.
    public static func all(
        _ futures: [Future<Output, Failure>]
    ) async -> Future<[Output], Failure> {
        typealias IndexedOutput = (index: Int, value: Output)
        guard !futures.isEmpty else { return await .init(with: .success([])) }
        return await .init { promise in
            await withThrowingTaskGroup(of: IndexedOutput.self) { group in
                var result: [IndexedOutput] = []
                result.reserveCapacity(futures.count)
                for (index, future) in futures.enumerated() {
                    group.addTask {
                        (index: index, value: try await future.value)
                    }
                }
                do {
                    for try await item in group { result.append(item) }
                    promise(
                        .success(
                            result.sorted { $0.index < $1.index }.map(\.value)
                        )
                    )
                } catch {
                    group.cancelAll()
                    promise(.failure(error))
                }
            }
        }
    }

    /// Combines into a single future, for all futures to be fulfilled, or for any to be rejected.
    ///
    /// If the returned future fulfills, it is fulfilled with an aggregating array of the values from the fulfilled futures,
    /// in the same order as provided.
    ///
    /// If it rejects, it is rejected with the error from the first future that was rejected.
    ///
    /// - Parameter futures: The futures to combine.
    ///
    /// - Returns: Already fulfilled future if no future provided, or a pending future
    ///            combining provided futures.
    public static func all(
        _ futures: Future<Output, Failure>...
    ) async -> Future<[Output], Failure> {
        return await Self.all(futures)
    }

    /// Combines into a single future, for all futures to have settled (each may fulfill or reject).
    ///
    /// Returns a future that fulfills after all of the given futures is either fulfilled or rejected,
    /// with an array of `Result`s that each describe the outcome of each future
    /// in the same order as provided.
    ///
    /// - Parameter futures: The futures to combine.
    ///
    /// - Returns: Already fulfilled future if no future provided, or a pending future
    ///            combining provided futures.
    public static func allSettled(
        _ futures: [Future<Output, Failure>]
    ) async -> Future<[FutureResult], Never> {
        typealias IndexedOutput = (index: Int, value: FutureResult)
        guard !futures.isEmpty else { return await .init(with: .success([])) }
        return await .init { promise in
            await withTaskGroup(of: IndexedOutput.self) { group in
                var result: [IndexedOutput] = []
                result.reserveCapacity(futures.count)
                for (index, future) in futures.enumerated() {
                    group.addTask {
                        do {
                            let value = try await future.value
                            return (index: index, value: .success(value))
                        } catch {
                            return (index: index, value: .failure(error))
                        }
                    }
                }
                for await item in group { result.append(item) }
                promise(
                    .success(
                        result.sorted { $0.index < $1.index }.map(\.value)
                    )
                )
            }
        }
    }

    /// Combines into a single future, for all futures to have settled (each may fulfill or reject).
    ///
    /// Returns a future that fulfills after all of the given futures is either fulfilled or rejected,
    /// with an array of `Result`s that each describe the outcome of each future
    /// in the same order as provided.
    ///
    /// - Parameter futures: The futures to combine.
    ///
    /// - Returns: Already fulfilled future if no future provided, or a pending future
    ///            combining provided futures.
    public static func allSettled(
        _ futures: Future<Output, Failure>...
    ) async -> Future<[FutureResult], Never> {
        return await Self.allSettled(futures)
    }

    /// Takes multiple futures and, returns a single future that fulfills with the value
    /// as soon as any of the futures is fulfilled or rejected.
    ///
    /// If the returned future fulfills, it is fulfilled with the value of the first future that fulfilled.
    ///
    /// If it rejects, it is rejected with the error from the first future that was rejected.
    ///
    /// - Parameter futures: The futures to combine.
    ///
    /// - Returns: A pending future combining provided futures, or a forever pending future
    ///            if no future provided.
    public static func race(
        _ futures: [Future<Output, Failure>]
    ) async -> Future<Output, Failure> {
        return await .init { promise in
            await withThrowingTaskGroup(of: Output.self) { group in
                futures.forEach { future in
                    group.addTask { try await future.value }
                }
                do {
                    if let first = try await group.next() {
                        promise(.success(first))
                        group.cancelAll()
                    }
                } catch {
                    promise(.failure(error))
                    group.cancelAll()
                }
            }
        }
    }

    /// Takes multiple futures and, returns a single future that fulfills with the value
    /// as soon as any of the futures is fulfilled or rejected.
    ///
    /// If the returned future fulfills, it is fulfilled with the value of the first future that fulfilled.
    ///
    /// If it rejects, it is rejected with the error from the first future that was rejected.
    ///
    /// - Parameter futures: The futures to combine.
    ///
    /// - Returns: A pending future combining provided futures, or a forever pending future
    ///            if no future provided.
    public static func race(
        _ futures: Future<Output, Failure>...
    ) async -> Future<Output, Failure> {
        return await Self.race(futures)
    }

    /// Takes multiple futures and, returns a single future that fulfills with the value as soon as one of the futures fulfills.
    ///
    /// If the returned future fulfills, it is fulfilled with the value of the first future that fulfilled.
    ///
    /// If all the provided futures are rejected, it rejects with `CancellationError`.
    ///
    /// - Parameter futures: The futures to wait for.
    ///
    /// - Returns: A pending future waiting for first fulfilled future from provided futures,
    ///            or a future rejected with `CancellationError` if no future provided.
    public static func any(
        _ futures: [Future<Output, Failure>]
    ) async -> Future<Output, Failure> {
        guard !futures.isEmpty else { return await .init(with: .cancelled) }
        return await .init { promise in
            await withTaskGroup(of: FutureResult.self) { group in
                futures.forEach { future in
                    group.addTask {
                        do {
                            let value = try await future.value
                            return .success(value)
                        } catch {
                            return .failure(error)
                        }
                    }
                }

                var fulfilled = false
                iterateFuture: for await item in group {
                    switch item {
                    case .success(let value):
                        promise(.success(value))
                        group.cancelAll()
                        fulfilled = true
                        break iterateFuture
                    case .failure:
                        continue iterateFuture
                    }
                }

                if !fulfilled {
                    promise(.failure(CancellationError()))
                    group.cancelAll()
                }
            }
        }
    }

    /// Takes multiple futures and, returns a single future that fulfills with the value as soon as one of the futures fulfills.
    ///
    /// If the returned future fulfills, it is fulfilled with the value of the first future that fulfilled.
    ///
    /// If all the provided futures are rejected, it rejects with `CancellationError`.
    ///
    /// - Parameter futures: The futures to wait for.
    ///
    /// - Returns: A pending future waiting for first fulfilled future from provided futures,
    ///            or a future rejected with `CancellationError` if no future provided.
    public static func any(
        _ futures: Future<Output, Failure>...
    ) async -> Future<Output, Failure> {
        return await Self.any(futures)
    }
}

private extension Result where Failure == Error {
    /// The cancelled error result.
    static var cancelled: Self { .failure(CancellationError()) }
}
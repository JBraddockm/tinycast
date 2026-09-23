import Foundation
import Network

@MainActor
final class MCPOAuthListener {
    nonisolated static let redirectURI = "http://127.0.0.1:4962/callback"
    private var task: Task<Void, Never>?
    private var ready: CheckedContinuation<Void, Error>?
    private var reply: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var accepted = false
    private var listener: NWListener?

    deinit {
        task?.cancel()
    }

    func start(
        state: String,
        issuer: String,
        requiresIssuer: Bool,
        timeout: Duration = .seconds(300)
    ) async throws {
        guard result == nil else {
            throw CancellationError()
        }

        guard let port = NWEndpoint.Port(rawValue: 4962) else {
            throw MCPOAuth.Failure.listenerUnavailable
        }

        let listener = try NWListener(
            using: .tcp,
            on: port
        )

        self.listener = listener

        try await withTaskCancellationHandler {
            try Task.checkCancellation()

            try await withCheckedThrowingContinuation { continuation in
                ready = continuation

                task = Task { [weak self] in
                    do {
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask { [weak self] in
                                try await self?.run(
                                    listener,
                                    state: state,
                                    issuer: issuer,
                                    requiresIssuer: requiresIssuer
                                )
                            }

                            group.addTask {
                                try await Task.sleep(for: timeout)
                                throw MCPOAuth.Failure.timedOut
                            }

                            defer {
                                group.cancelAll()
                            }

                            _ = try await group.next()
                        }
                    } catch {
                        self?.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func code() async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()

            if let result {
                return try result.get()
            }

            return try await withCheckedThrowingContinuation {
                reply = $0
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<String, Error>) {
        guard self.result == nil else {
            return
        }

        self.result = result

        ready?.resume(
            throwing: result.failure ?? CancellationError()
        )
        ready = nil

        reply?.resume(with: result)
        reply = nil

        listener?.cancel()
        listener = nil

        task?.cancel()
        task = nil
    }

    private enum ListenerEvent {
        case ready
        case connection(NWConnection)
        case failed(NWError)
        case cancelled
    }

    private func run(
        _ listener: NWListener,
        state: String,
        issuer: String,
        requiresIssuer: Bool
    ) async throws {
        let events = AsyncStream<ListenerEvent> { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.yield(.ready)

                case .failed(let error):
                    continuation.yield(.failed(error))
                    continuation.finish()

                case .cancelled:
                    continuation.yield(.cancelled)
                    continuation.finish()

                default:
                    break
                }
            }

            listener.newConnectionHandler = { connection in
                continuation.yield(.connection(connection))
            }

            continuation.onTermination = { @Sendable _ in
                listener.stateUpdateHandler = nil
                listener.newConnectionHandler = nil
                listener.cancel()
            }

            listener.start(queue: .main)
        }

        for await event in events {
            switch event {
            case .ready:
                ready?.resume()
                ready = nil

            case .connection(let connection):
                connection.start(queue: .main)

                Task { @MainActor [weak self] in
                    await self?.receive(
                        connection,
                        state: state,
                        issuer: issuer,
                        requiresIssuer: requiresIssuer
                    )
                }

            case .failed:
                finish(
                    .failure(
                        MCPOAuth.Failure.listenerUnavailable
                    )
                )
                return

            case .cancelled:
                if result == nil {
                    finish(
                        .failure(CancellationError())
                    )
                }
                return
            }
        }
    }

    private func read(
        _ connection: NWConnection,
        state: String,
        issuer: String,
        requiresIssuer: Bool
    ) async throws {
        var bytes = Data()

        while bytes.count < 8192 {
            let chunk = try await receive(
                from: connection,
                maximumLength: 8192 - bytes.count
            )

            if chunk.isEmpty {
                break
            }

            bytes.append(chunk)

            if bytes.range(
                of: Data("\r\n\r\n".utf8)
            ) != nil {
                break
            }
        }

        guard !accepted else {
            return
        }

        guard
            let request = String(
                bytes: bytes,
                encoding: .utf8
            ),
            request.contains("\r\n\r\n")
        else {
            return
        }

        let line =
            request
                .components(separatedBy: "\r\n")
                .first ?? ""

        let parts = line.split(separator: " ")

        var outcome: Result<String, Error>?

        if parts.count == 3, parts[0] == "GET" {
            do {
                let code = try MCPOAuth.callback(
                    String(parts[1]),
                    state: state,
                    issuer: issuer,
                    requiresIssuer: requiresIssuer
                )

                outcome = .success(code)

            } catch MCPOAuth.Failure.denied {
                outcome = .failure(
                    MCPOAuth.Failure.denied
                )

            } catch {
                outcome = nil
            }
        }

        let status =
            outcome == nil
                ? "400 Bad Request"
                : "200 OK"

        let page =
            outcome == nil
                ? "Invalid sign-in response."
                : "Return to Tinycast. You can close this tab."

        let response =
            "HTTP/1.1 \(status)\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Cache-Control: no-store\r\n" +
            "Content-Security-Policy: default-src 'none'\r\n" +
            "Connection: close\r\n" +
            "Content-Length: \(page.utf8.count)\r\n" +
            "\r\n" +
            page

        if outcome != nil {
            accepted = true
        }

        try await send(
            Data(response.utf8),
            on: connection
        )

        if let outcome {
            finish(outcome)
        }
    }

    private func receive(
        _ connection: NWConnection,
        state: String,
        issuer: String,
        requiresIssuer: Bool
    ) async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    try await self?.read(
                        connection,
                        state: state,
                        issuer: issuer,
                        requiresIssuer: requiresIssuer
                    )
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                }

                defer {
                    group.cancelAll()
                    connection.cancel()
                }

                _ = try await group.next()
            }
        } catch {
            connection.cancel()
        }
    }

    private func receive(
        from connection: NWConnection,
        maximumLength: Int
    ) async throws -> Data {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in

            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximumLength
            ) { data, _, isComplete, error in

                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(
        _ data: Data,
        on connection: NWConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in

            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }
}

private extension Result
where Success == String, Failure == Error {
    var failure: Error? {
        if case .failure(let error) = self {
            return error
        }

        return nil
    }
}

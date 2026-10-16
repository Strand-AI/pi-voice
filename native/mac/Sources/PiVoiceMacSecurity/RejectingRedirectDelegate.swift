import Foundation

public struct URLSessionTaskCompletionReceipt: @unchecked Sendable {
    public enum Kind: Equatable, Sendable {
        case taskCompleted
        case webSocketClosed
    }

    private let sourceSession: URLSession
    private let sourceTask: URLSessionTask
    public let sessionIdentifier: ObjectIdentifier
    public let taskObjectIdentifier: ObjectIdentifier
    public let taskIdentifier: Int
    public let kind: Kind
    public let webSocketCloseCode: Int?

    public init(
        session: URLSession,
        task: URLSessionTask,
        kind: Kind,
        webSocketCloseCode: Int? = nil
    ) {
        sourceSession = session
        sourceTask = task
        sessionIdentifier = ObjectIdentifier(session)
        taskObjectIdentifier = ObjectIdentifier(task)
        taskIdentifier = task.taskIdentifier
        self.kind = kind
        if let webSocketCloseCode {
            self.webSocketCloseCode = webSocketCloseCode
        } else if let webSocketTask = task as? URLSessionWebSocketTask,
                  webSocketTask.closeCode != .invalid {
            self.webSocketCloseCode = webSocketTask.closeCode.rawValue
        } else {
            self.webSocketCloseCode = nil
        }
    }

    public func matches(session: URLSession, task: URLSessionTask) -> Bool {
        sourceSession === session && sourceTask === task &&
            sessionIdentifier == ObjectIdentifier(session) &&
            taskObjectIdentifier == ObjectIdentifier(task) &&
            taskIdentifier == task.taskIdentifier
    }
}

/// Shared by every native authentication and ordinary gateway URLSession.
/// Returning nil keeps one-use pairing bodies and durable device cookies on the
/// exact requested endpoint even for same-host redirects to another port.
/// Completion receipts contain identity only; no URL, cookie, body, or secret.
public final class RejectingRedirectDelegate: NSObject, URLSessionTaskDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    public static let rejectsAllRedirects = true

    private let completion: @Sendable (URLSessionTaskCompletionReceipt) -> Void

    public init(
        completion: @escaping @Sendable (URLSessionTaskCompletionReceipt) -> Void = { _ in }
    ) {
        self.completion = completion
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        completion(.init(session: session, task: task, kind: .taskCompleted))
    }

    /// Foundation documents this only for a WebSocket close frame. Abrupt TCP
    /// completion is covered separately by `didCompleteWithError` above.
    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        completion(.init(
            session: session,
            task: webSocketTask,
            kind: .webSocketClosed,
            webSocketCloseCode: closeCode.rawValue
        ))
    }
}

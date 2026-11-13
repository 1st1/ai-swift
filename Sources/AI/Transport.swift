import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum HTTPEvent: Sendable {
  case response(status: Int)
  case data(Data)
}

public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) -> AsyncThrowingStream<HTTPEvent, any Error>
}

/// Uses data delegate callbacks because URLSession.bytes is unavailable on Linux.
public struct URLSessionTransport: HTTPTransport {
  public init() {}

  public func send(_ request: URLRequest) -> AsyncThrowingStream<HTTPEvent, any Error> {
    AsyncThrowingStream { continuation in
      let delegate = StreamingDelegate(continuation: continuation)
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpCookieStorage = nil
      configuration.urlCredentialStorage = nil
      let session = URLSession(
        configuration: configuration, delegate: delegate,
        delegateQueue: nil)
      let task = session.dataTask(with: request)
      continuation.onTermination = { _ in session.invalidateAndCancel() }
      task.resume()
    }
  }
}

private final class StreamingDelegate: NSObject, URLSessionDataDelegate, Sendable {
  let continuation: AsyncThrowingStream<HTTPEvent, any Error>.Continuation

  init(continuation: AsyncThrowingStream<HTTPEvent, any Error>.Continuation) {
    self.continuation = continuation
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse else {
      continuation.finish(throwing: AIError.invalidResponse("Expected HTTP response."))
      completionHandler(.cancel)
      return
    }
    continuation.yield(.response(status: response.statusCode))
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    continuation.yield(.data(data))
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    session.finishTasksAndInvalidate()
  }

  // Surface redirects as HTTP errors rather than forwarding credentials elsewhere.
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

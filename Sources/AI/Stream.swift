import Foundation

public typealias EventSink = @Sendable (Event) -> Void

/// A single-consumer event sequence with a separately awaitable final result.
/// Runs eagerly. Use `defer { stream.cancel() }` if you may break iteration early.
public final class Stream<Result: Sendable>: AsyncSequence, Sendable {
  public typealias Element = Event
  public typealias AsyncIterator = AsyncThrowingStream<Event, any Error>.Iterator

  private let events: AsyncThrowingStream<Event, any Error>
  private let task: Task<Result, any Error>

  public init(_ operation: @escaping @Sendable (@escaping EventSink) async throws -> Result) {
    let (events, continuation) = AsyncThrowingStream<Event, any Error>.makeStream()
    self.events = events
    let task = Task {
      do {
        try Task.checkCancellation()
        let result = try await operation { continuation.yield($0) }
        try Task.checkCancellation()
        continuation.finish()
        return result
      } catch {
        let failure: any Error = Task.isCancelled ? CancellationError() : error
        continuation.finish(throwing: failure)
        throw failure
      }
    }
    self.task = task
    continuation.onTermination = { reason in
      if case .cancelled = reason { task.cancel() }
    }
  }

  public func makeAsyncIterator() -> AsyncIterator { events.makeAsyncIterator() }
  public func cancel() { task.cancel() }

  public var result: Result {
    get async throws {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await task.value
      } onCancel: {
        task.cancel()
      }
    }
  }

  deinit { task.cancel() }
}

public protocol Provider: Sendable {
  func stream(_ request: ModelRequest) -> Stream<ModelResponse>
}

public struct Model: Sendable {
  public let id: String
  public let provider: any Provider

  public init(_ id: String, provider: any Provider) {
    self.id = id
    self.provider = provider
  }

  public static func gateway(_ id: String, apiKey: String? = nil) throws -> Self {
    let key = apiKey ?? ProcessInfo.processInfo.environment["AI_GATEWAY_API_KEY"]
    guard let key, !key.isEmpty else {
      throw AIError.configuration("Set AI_GATEWAY_API_KEY or pass apiKey explicitly.")
    }
    return .init(
      id,
      provider: try OpenAICompatibleProvider(
        baseURL: URL(string: "https://ai-gateway.vercel.sh/v1")!, apiKey: key))
  }
}

public struct ModelOptions: Sendable, Equatable {
  public var temperature: Double?
  public var maxCompletionTokens: Int?
  public var includeUsage: Bool

  public init(
    temperature: Double? = nil, maxCompletionTokens: Int? = nil,
    includeUsage: Bool = true
  ) {
    self.temperature = temperature
    self.maxCompletionTokens = maxCompletionTokens
    self.includeUsage = includeUsage
  }
}

public struct ModelRequest: Sendable {
  public var modelID: String
  public var messages: [Message]
  public var tools: [ToolDefinition]
  public var options: ModelOptions

  public init(
    modelID: String, messages: [Message], tools: [ToolDefinition] = [],
    options: ModelOptions = .init()
  ) {
    self.modelID = modelID
    self.messages = messages
    self.tools = tools
    self.options = options
  }
}

/// One model turn. Tool definitions are sent to the model, but no tools run here.
public func stream(
  _ model: Model, messages: [Message], tools: [ToolDefinition] = [],
  options: ModelOptions = .init()
) -> Stream<ModelResponse> {
  model.provider.stream(
    .init(
      modelID: model.id, messages: messages,
      tools: tools, options: options))
}

import Foundation

@testable import AI

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

actor Script {
  private var responses: [ModelResponse]
  private(set) var requests: [ModelRequest] = []

  init(_ responses: [ModelResponse]) { self.responses = responses }

  func next(_ request: ModelRequest) throws -> ModelResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw AIError.invalidResponse("No scripted response left.") }
    return responses.removeFirst()
  }
}

struct ScriptedProvider: Provider {
  let script: Script
  func stream(_ request: ModelRequest) -> AI.Stream<ModelResponse> {
    AI.Stream { emit in
      let response = try await script.next(request)
      emit(.streamStart(model: request.modelID))
      if !response.text.isEmpty { emit(.textDelta(response.text)) }
      for call in response.message.toolCalls { emit(.toolCall(call)) }
      emit(.streamEnd(response))
      return response
    }
  }
}

actor RequestLog {
  private(set) var requests: [URLRequest] = []
  func append(_ request: URLRequest) { requests.append(request) }
}

struct FixtureTransport: HTTPTransport {
  var status = 200
  var chunks: [Data]
  let log = RequestLog()

  func send(_ request: URLRequest) -> AsyncThrowingStream<HTTPEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        await log.append(request)
        continuation.yield(.response(status: status))
        for chunk in chunks { continuation.yield(.data(chunk)) }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

let emptySchema: JSONValue = .object([
  "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false),
])

func fixtureProvider(_ body: String, status: Int = 200) throws -> OpenAICompatibleProvider {
  try OpenAICompatibleProvider(
    baseURL: URL(string: "https://example.invalid/v1")!,
    transport: FixtureTransport(status: status, chunks: body.utf8.map { Data([$0]) }))
}

func drain<T>(_ stream: AI.Stream<T>) async throws -> (T, [Event]) {
  defer { stream.cancel() }
  var events: [Event] = []
  for try await event in stream { events.append(event) }
  return (try await stream.result, events)
}

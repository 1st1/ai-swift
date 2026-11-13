import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct OpenAICompatibleProvider: Provider {
  public let baseURL: URL
  private let apiKey: String?
  private let transport: any HTTPTransport
  private let timeout: TimeInterval

  public init(
    baseURL: URL, apiKey: String? = nil, timeout: TimeInterval = 120,
    transport: any HTTPTransport = URLSessionTransport()
  ) throws {
    guard ["https", "http"].contains(baseURL.scheme), baseURL.host != nil,
      baseURL.query == nil, baseURL.fragment == nil,
      baseURL.user == nil, baseURL.password == nil, timeout > 0
    else {
      throw AIError.configuration("Expected an HTTP(S) base URL and positive timeout.")
    }
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.timeout = timeout
    self.transport = transport
  }

  public func stream(_ request: ModelRequest) -> Stream<ModelResponse> {
    Stream { emit in
      let httpRequest = try makeRequest(request)
      var parser = SSEParser()
      var accumulator = CompletionAccumulator()
      var status: Int?
      var errorBody = Data()
      emit(.streamStart(model: request.modelID))

      for try await event in transport.send(httpRequest) {
        try Task.checkCancellation()
        switch event {
        case .response(let code): status = code
        case .data(let data):
          guard let status else {
            throw AIError.invalidResponse("Received body before HTTP status.")
          }
          guard (200..<300).contains(status) else {
            errorBody.append(data.prefix(max(0, 16_384 - errorBody.count)))
            continue
          }
          for payload in try parser.feed(data) {
            if payload == "[DONE]" {
              let result = try accumulator.finish(emit: emit)
              emit(.streamEnd(result))
              return result
            }
            try accumulator.feed(payload, emit: emit)
          }
        }
      }
      try Task.checkCancellation()
      if let status, !(200..<300).contains(status) {
        throw AIError.http(status: status, body: String(decoding: errorBody, as: UTF8.self))
      }
      throw AIError.incompleteResponse
    }
  }

  func makeRequest(_ request: ModelRequest) throws -> URLRequest {
    guard !request.modelID.isEmpty else { throw AIError.configuration("Model ID is empty.") }
    var messages: [JSONValue] = []
    for message in request.messages {
      if message.role == .tool {
        for result in message.toolResults {
          let content: String
          if result.isError {
            content = try JSONValue.object(["error": result.value]).jsonString()
          } else {
            content = try result.value.string ?? result.value.jsonString()
          }
          messages.append(
            .object([
              "role": .string("tool"), "tool_call_id": .string(result.callID),
              "content": .string(content),
            ]))
        }
        continue
      }
      var value: [String: JSONValue] = [
        "role": .string(message.role.rawValue), "content": .string(message.text),
      ]
      if !message.reasoning.isEmpty { value["reasoning_content"] = .string(message.reasoning) }
      if !message.toolCalls.isEmpty {
        value["tool_calls"] = .array(
          message.toolCalls.map { call in
            .object([
              "id": .string(call.id), "type": .string("function"),
              "function": .object([
                "name": .string(call.name),
                "arguments": .string(call.arguments),
              ]),
            ])
          })
      }
      messages.append(.object(value))
    }
    var body: [String: JSONValue] = [
      "model": .string(request.modelID), "messages": .array(messages), "stream": .bool(true),
    ]
    if request.options.includeUsage {
      body["stream_options"] = .object(["include_usage": .bool(true)])
    }
    if let temperature = request.options.temperature { body["temperature"] = .number(temperature) }
    if let tokens = request.options.maxCompletionTokens {
      guard tokens > 0 else { throw AIError.configuration("maxCompletionTokens must be positive.") }
      body["max_completion_tokens"] = .integer(Int64(tokens))
    }
    if !request.tools.isEmpty {
      body["tools"] = .array(
        request.tools.map { tool in
          .object([
            "type": .string("function"),
            "function": .object([
              "name": .string(tool.name), "description": .string(tool.description),
              "parameters": tool.parameters,
            ]),
          ])
        })
    }
    var http = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
    http.httpMethod = "POST"
    http.timeoutInterval = timeout
    http.setValue("application/json", forHTTPHeaderField: "Content-Type")
    http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    if let apiKey, !apiKey.isEmpty {
      http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    http.httpBody = try JSONEncoder().encode(JSONValue.object(body))
    return http
  }
}

private struct CompletionChunk: Decodable {
  struct Choice: Decodable {
    struct Delta: Decodable {
      struct Call: Decodable {
        struct Function: Decodable {
          var name: String?
          var arguments: String?
        }
        var index: Int
        var id: String?
        var function: Function?
      }
      var content: String?
      var reasoningContent: String?
      var toolCalls: [Call]?
    }
    var index: Int
    var delta: Delta?
    var finishReason: String?
  }
  struct TokenUsage: Decodable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
  }
  var choices: [Choice]?
  var usage: TokenUsage?
  var error: JSONValue?
}

private struct CompletionAccumulator {
  var message = Message.assistant("")
  var calls: [Int: ToolCall] = [:]
  var usage = Usage()
  var finishReason: String?

  mutating func feed(_ payload: String, emit: EventSink) throws {
    let chunk: CompletionChunk
    do {
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      chunk = try decoder.decode(CompletionChunk.self, from: Data(payload.utf8))
    } catch {
      throw AIError.invalidResponse("Malformed Chat Completions chunk: \(error)")
    }
    if let error = chunk.error, error != .null {
      throw AIError.invalidResponse(try error.jsonString())
    }
    if let tokens = chunk.usage {
      usage = .init(
        inputTokens: tokens.promptTokens ?? 0,
        outputTokens: tokens.completionTokens ?? 0, totalTokens: tokens.totalTokens)
    }
    for choice in chunk.choices ?? [] {
      guard choice.index == 0 else {
        throw AIError.invalidResponse("Only one completion choice is supported.")
      }
      guard finishReason == nil else {
        throw AIError.invalidResponse("Received a choice after its finish reason.")
      }
      if let delta = choice.delta {
        if let text = delta.content, !text.isEmpty {
          message.text += text
          emit(.textDelta(text))
        }
        if let reasoning = delta.reasoningContent, !reasoning.isEmpty {
          message.reasoning += reasoning
          emit(.reasoningDelta(reasoning))
        }
        for fragment in delta.toolCalls ?? [] {
          guard fragment.index >= 0 else { throw AIError.invalidResponse("Negative tool index.") }
          var call = calls[fragment.index] ?? ToolCall(id: "", name: "", arguments: "")
          if let id = fragment.id { call.id += id }
          if let name = fragment.function?.name { call.name += name }
          let arguments = fragment.function?.arguments ?? ""
          call.arguments += arguments
          calls[fragment.index] = call
          emit(
            .toolCallDelta(
              index: fragment.index, id: fragment.id,
              name: fragment.function?.name, arguments: arguments))
        }
      }
      if let reason = choice.finishReason { finishReason = reason }
    }
  }

  mutating func finish(emit: EventSink) throws -> ModelResponse {
    guard let finishReason else { throw AIError.incompleteResponse }
    var ids = Set<String>()
    for index in calls.keys.sorted() {
      let call = calls[index]!
      guard !call.id.isEmpty, !call.name.isEmpty, ids.insert(call.id).inserted else {
        throw AIError.invalidResponse("Missing or duplicate tool identity.")
      }
      message.toolCalls.append(call)
      emit(.toolCall(call))
    }
    if finishReason == "tool_calls", calls.isEmpty {
      throw AIError.invalidResponse("Tool-call finish reason without tool calls.")
    }
    return .init(message: message, usage: usage, finishReason: finishReason)
  }
}

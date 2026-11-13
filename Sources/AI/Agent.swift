import Foundation

/// Immutable configuration; each run owns an independent conversation and task tree.
public struct Agent: Sendable {
  public let tools: [Tool]
  public let maxSteps: Int
  public let maxConcurrentTools: Int

  public init(tools: [Tool] = [], maxSteps: Int = 20, maxConcurrentTools: Int = 4) throws {
    guard maxSteps > 0, maxConcurrentTools > 0 else {
      throw AIError.configuration("Step and tool concurrency limits must be positive.")
    }
    var names = Set<String>()
    for tool in tools {
      let name = tool.definition.name
      guard !name.isEmpty, name.utf8.count <= 64,
        name.utf8.allSatisfy({
          (65...90).contains($0) || (97...122).contains($0)
            || (48...57).contains($0) || $0 == 95 || $0 == 45
        }),
        names.insert(name).inserted
      else {
        throw AIError.configuration("Invalid or duplicate tool name: \(name)")
      }
      guard tool.definition.parameters["type"] == .string("object") else {
        throw AIError.configuration("Tool \(name) requires an object JSON schema.")
      }
    }
    self.tools = tools
    self.maxSteps = maxSteps
    self.maxConcurrentTools = maxConcurrentTools
  }

  public func run(
    _ model: Model, messages: [Message],
    options: ModelOptions = .init()
  ) -> Stream<AgentResult> {
    Stream { emit in
      var history = messages
      var usage = Usage()
      for step in 1...maxSteps {
        try Task.checkCancellation()
        emit(.stepStart(step))
        let turn = stream(
          model, messages: history, tools: tools.map(\.definition), options: options)
        let response = try await withTaskCancellationHandler {
          defer { turn.cancel() }
          for try await event in turn {
            try Task.checkCancellation()
            emit(event)
          }
          return try await turn.result
        } onCancel: {
          turn.cancel()
        }
        history.append(response.message)
        usage = usage + response.usage
        let calls = response.message.toolCalls
        if calls.isEmpty {
          emit(.stepEnd(step))
          let result = AgentResult(messages: history, usage: usage, steps: step)
          emit(.agentEnd(result))
          return result
        }
        // Never execute partial tool arguments from a token-limited or filtered response.
        guard response.finishReason == "tool_calls" || response.finishReason == "stop" else {
          throw AIError.invalidResponse(
            "Cannot execute tools after finish reason \(response.finishReason).")
        }
        // No side effects on a turn for which we cannot request a follow-up response.
        guard step < maxSteps else { throw AIError.stepLimitExceeded(maxSteps) }
        guard Set(calls.map(\.id)).count == calls.count,
          calls.allSatisfy({ !$0.id.isEmpty })
        else {
          throw AIError.invalidResponse("Missing or duplicate tool call ID.")
        }
        let results = try await execute(calls, messages: history, emit: emit)
        history.append(.tool(results))
        emit(.stepEnd(step))
      }
      throw AIError.stepLimitExceeded(maxSteps)
    }
  }

  private func execute(
    _ calls: [ToolCall], messages: [Message],
    emit: @escaping EventSink
  ) async throws -> [ToolResult] {
    try await withThrowingTaskGroup(of: (Int, ToolResult).self) { group in
      let initial = min(calls.count, maxConcurrentTools)
      var results: [Int: ToolResult] = [:]
      for index in 0..<initial {
        group.addTask { (index, try await execute(calls[index], messages: messages, emit: emit)) }
      }
      var nextIndex = initial
      while let (index, result) = try await group.next() {
        try Task.checkCancellation()
        results[index] = result
        emit(.toolResult(result))
        if nextIndex < calls.count {
          let next = nextIndex
          group.addTask { (next, try await execute(calls[next], messages: messages, emit: emit)) }
          nextIndex += 1
        }
      }
      // Events arrive in completion order; history stays in the model's original call order.
      return calls.indices.map { results[$0]! }
    }
  }

  private func execute(
    _ call: ToolCall, messages: [Message],
    emit: @escaping EventSink
  ) async throws -> ToolResult {
    do {
      try Task.checkCancellation()
      guard let tool = tools.first(where: { $0.definition.name == call.name }) else {
        throw AIError.configuration("Unknown tool: \(call.name)")
      }
      let arguments = try JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))
      guard case .object = arguments else {
        throw AIError.configuration("Tool arguments must be a JSON object.")
      }
      let output = try await tool.execute(
        arguments, .init(call: call, messages: messages, emit: emit))
      try Task.checkCancellation()
      return .init(
        callID: call.id, name: call.name, value: output.value,
        subagentMessages: output.subagentMessages)
    } catch {
      // Cancellation must stop the run, never become a model-visible tool error.
      if error is CancellationError || Task.isCancelled { throw CancellationError() }
      return .init(
        callID: call.id, name: call.name,
        value: .string(String(describing: error)), isError: true)
    }
  }

  /// The child gets an isolated conversation; its final text becomes the parent's tool result.
  public func asTool(
    name: String, description: String, model: Model,
    instructions: String? = nil, options: ModelOptions = .init()
  ) -> Tool {
    let definition = ToolDefinition(
      name: name, description: description,
      parameters: .object([
        "type": .string("object"),
        "properties": .object(["prompt": .object(["type": .string("string")])]),
        "required": .array([.string("prompt")]), "additionalProperties": .bool(false),
      ]))
    return Tool(definition: definition) { arguments, context in
      struct Arguments: Decodable { let prompt: String }
      let input = try arguments.decode(Arguments.self)
      var messages: [Message] = []
      if let instructions { messages.append(.system(instructions)) }
      messages.append(.user(input.prompt))
      let result = try await context.run(self, model: model, messages: messages, options: options)
      return ToolOutput(value: .string(result.output), subagentMessages: result.messages)
    }
  }
}

import Foundation

public struct ToolDefinition: Codable, Sendable, Equatable {
  public var name: String
  public var description: String
  public var parameters: JSONValue

  public init(name: String, description: String, parameters: JSONValue) {
    self.name = name
    self.description = description
    self.parameters = parameters
  }
}

struct ToolOutput: Sendable {
  var value: JSONValue
  var subagentMessages: [Message]?
}

public struct Tool: Sendable {
  public let definition: ToolDefinition
  let execute: @Sendable (JSONValue, ToolContext) async throws -> ToolOutput

  public init(
    name: String, description: String, parameters: JSONValue,
    execute: @escaping @Sendable (JSONValue, ToolContext) async throws -> JSONValue
  ) {
    self.definition = .init(name: name, description: description, parameters: parameters)
    self.execute = { arguments, context in
      ToolOutput(value: try await execute(arguments, context))
    }
  }

  /// Explicit schemas avoid macros or runtime reflection. Decodable validates arguments locally.
  public init<Arguments: Decodable & Sendable>(
    name: String, description: String, parameters: JSONValue, arguments: Arguments.Type,
    execute: @escaping @Sendable (Arguments, ToolContext) async throws -> JSONValue
  ) {
    self.init(name: name, description: description, parameters: parameters) { value, context in
      try await execute(value.decode(Arguments.self), context)
    }
  }

  init(
    definition: ToolDefinition,
    execute: @escaping @Sendable (JSONValue, ToolContext) async throws -> ToolOutput
  ) {
    self.definition = definition
    self.execute = execute
  }
}

public struct ToolContext: Sendable {
  public let call: ToolCall
  public let messages: [Message]
  private let emit: EventSink

  init(call: ToolCall, messages: [Message], emit: @escaping EventSink) {
    self.call = call
    self.messages = messages
    self.emit = emit
  }

  /// For custom tools that delegate some of their work to another agent.
  public func run(
    _ agent: Agent, model: Model, messages: [Message],
    options: ModelOptions = .init()
  ) async throws -> AgentResult {
    let child = agent.run(model, messages: messages, options: options)
    defer { child.cancel() }
    return try await withTaskCancellationHandler {
      for try await event in child {
        try Task.checkCancellation()
        emit(.subagentEvent(toolCallID: call.id, event: event))
      }
      return try await child.result
    } onCancel: {
      child.cancel()
    }
  }
}

import Foundation

public enum AIError: Error, Sendable, Equatable, CustomStringConvertible {
  case configuration(String)
  case http(status: Int, body: String)
  case invalidResponse(String)
  case incompleteResponse
  case stepLimitExceeded(Int)

  public var description: String {
    switch self {
    case .configuration(let message): return message
    case .http(let status, let body): return "HTTP \(status): \(body)"
    case .invalidResponse(let message): return "Invalid provider response: \(message)"
    case .incompleteResponse: return "Provider stream ended before a complete response."
    case .stepLimitExceeded(let limit): return "Agent reached its limit of \(limit) model steps."
    }
  }
}

public struct ToolCall: Codable, Sendable, Equatable {
  public var id: String
  public var name: String
  /// Kept as JSON text so malformed model arguments can be returned as a tool error.
  public var arguments: String

  public init(id: String, name: String, arguments: String) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

public struct ToolResult: Codable, Sendable, Equatable {
  public var callID: String
  public var name: String
  public var value: JSONValue
  public var isError: Bool
  public var subagentMessages: [Message]?

  public init(
    callID: String, name: String, value: JSONValue, isError: Bool = false,
    subagentMessages: [Message]? = nil
  ) {
    self.callID = callID
    self.name = name
    self.value = value
    self.isError = isError
    self.subagentMessages = subagentMessages
  }
}

public struct Message: Codable, Sendable, Equatable {
  public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
  public var role: Role
  public var text: String
  public var reasoning: String
  public var toolCalls: [ToolCall]
  public var toolResults: [ToolResult]

  public init(
    role: Role, text: String = "", reasoning: String = "",
    toolCalls: [ToolCall] = [], toolResults: [ToolResult] = []
  ) {
    self.role = role
    self.text = text
    self.reasoning = reasoning
    self.toolCalls = toolCalls
    self.toolResults = toolResults
  }

  public static func system(_ text: String) -> Self { .init(role: .system, text: text) }
  public static func user(_ text: String) -> Self { .init(role: .user, text: text) }
  public static func assistant(_ text: String, toolCalls: [ToolCall] = []) -> Self {
    .init(role: .assistant, text: text, toolCalls: toolCalls)
  }
  public static func tool(_ results: [ToolResult]) -> Self {
    .init(role: .tool, toolResults: results)
  }
}

public struct Usage: Codable, Sendable, Equatable {
  public var inputTokens: Int
  public var outputTokens: Int
  public var totalTokens: Int

  public init(inputTokens: Int = 0, outputTokens: Int = 0, totalTokens: Int? = nil) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.totalTokens = totalTokens ?? inputTokens + outputTokens
  }

  public static func + (lhs: Self, rhs: Self) -> Self {
    .init(
      inputTokens: lhs.inputTokens + rhs.inputTokens,
      outputTokens: lhs.outputTokens + rhs.outputTokens,
      totalTokens: lhs.totalTokens + rhs.totalTokens)
  }
}

public struct ModelResponse: Codable, Sendable, Equatable {
  public var message: Message
  public var usage: Usage
  public var finishReason: String
  public var text: String { message.text }

  public init(message: Message, usage: Usage = .init(), finishReason: String = "stop") {
    self.message = message
    self.usage = usage
    self.finishReason = finishReason
  }
}

public struct AgentResult: Codable, Sendable, Equatable {
  public var messages: [Message]
  /// Usage for this agent's model turns; nested usage is available in nested events.
  public var usage: Usage
  public var steps: Int
  public var output: String { messages.last(where: { $0.role == .assistant })?.text ?? "" }

  public init(messages: [Message], usage: Usage, steps: Int) {
    self.messages = messages
    self.usage = usage
    self.steps = steps
  }
}

public indirect enum Event: Sendable, Equatable {
  case streamStart(model: String)
  case textDelta(String)
  case reasoningDelta(String)
  case toolCallDelta(index: Int, id: String?, name: String?, arguments: String)
  case toolCall(ToolCall)
  case streamEnd(ModelResponse)
  case stepStart(Int)
  case stepEnd(Int)
  case toolResult(ToolResult)
  case subagentEvent(toolCallID: String, event: Event)
  case agentEnd(AgentResult)
}

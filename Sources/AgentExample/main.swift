import AI
import Foundation

@main
struct AgentExample {
  static func main() async throws {
    let env = ProcessInfo.processInfo.environment
    let modelID = env["AI_MODEL"] ?? "anthropic/claude-sonnet-4.6"
    let model: Model
    if let base = env["AI_BASE_URL"], let url = URL(string: base) {
      model = Model(
        modelID,
        provider: try OpenAICompatibleProvider(
          baseURL: url, apiKey: env["AI_API_KEY"]))
    } else {
      model = try .gateway(modelID)
    }

    struct FactsInput: Decodable, Sendable { let topic: String }
    let facts = Tool(
      name: "get_facts", description: "Look up facts about a planet.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object(["topic": .object(["type": .string("string")])]),
        "required": .array([.string("topic")]), "additionalProperties": .bool(false),
      ]), arguments: FactsInput.self
    ) { input, _ in
      .string(
        input.topic.lowercased() == "mars"
          ? "Mars has two moons: Phobos and Deimos. A day lasts 24.6 hours."
          : "No local facts available for \(input.topic).")
    }
    let researcher = try Agent(tools: [facts])
    let agent = try Agent(tools: [
      researcher.asTool(
        name: "research", description: "Ask a specialist to research a planet.", model: model,
        instructions: "Use get_facts to look up the planet, then give a concise answer."
      )
    ])
    let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
    let run = agent.run(
      model,
      messages: [
        .system("Use research to answer questions about planets, then summarize the findings."),
        .user(prompt.isEmpty ? "Tell me about Mars." : prompt),
      ])
    defer { run.cancel() }
    for try await event in run {
      switch event {
      case .textDelta(let text):
        FileHandle.standardOutput.write(Data(text.utf8))
      case .subagentEvent(_, .textDelta(let text)):
        FileHandle.standardError.write(Data(text.utf8))
      default: break
      }
    }
    let result = try await run.result
    print("\n[\(result.steps) steps; \(result.usage.totalTokens) parent tokens]")
  }
}

import Foundation
import Testing

@testable import AI

// @lat: [[tests#Behavior specifications#Agent behavior#Tool round trip]]
@Test func agentExecutesTypedToolAndContinuesConversation() async throws {
  struct Input: Decodable, Sendable { let city: String }
  let weather = Tool(
    name: "weather", description: "Weather", parameters: emptySchema,
    arguments: Input.self
  ) { input, _ in .string("Sunny in \(input.city)") }
  let script = Script([
    .init(
      message: .assistant(
        "Checking",
        toolCalls: [
          .init(id: "w", name: "weather", arguments: "{\"city\":\"Paris\"}")
        ]), usage: .init(inputTokens: 10, outputTokens: 2), finishReason: "tool_calls"),
    .init(message: .assistant("It is sunny."), usage: .init(inputTokens: 20, outputTokens: 3)),
  ])
  let agent = try Agent(tools: [weather])
  let (result, events) = try await drain(
    agent.run(
      Model("test", provider: ScriptedProvider(script: script)),
      messages: [.user("Weather in Paris?")]))
  #expect(result.output == "It is sunny.")
  #expect(result.steps == 2)
  #expect(result.usage == Usage(inputTokens: 30, outputTokens: 5))
  #expect(result.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
  let requests = await script.requests
  #expect(requests[1].messages[2].toolResults[0].value == .string("Sunny in Paris"))
  #expect(events.last == .agentEnd(result))
  #expect(try JSONDecoder().decode(AgentResult.self, from: JSONEncoder().encode(result)) == result)
}

// @lat: [[tests#Behavior specifications#Agent behavior#Direct streaming]]
@Test func directStreamDoesNotExecuteTools() async throws {
  let call = ToolCall(id: "a", name: "anything", arguments: "{}")
  let script = Script([
    .init(message: .assistant("", toolCalls: [call]), finishReason: "tool_calls")
  ])
  let (result, _) = try await drain(
    stream(Model("test", provider: ScriptedProvider(script: script)), messages: []))
  #expect(result.message.toolCalls == [call])
  #expect(await script.requests.count == 1)
}

// @lat: [[tests#Behavior specifications#Agent behavior#Recoverable tool errors]]
@Test func unknownMalformedAndThrowingToolsBecomeErrorResults() async throws {
  enum Failure: Error { case unavailable }
  let tool = Tool(name: "fail", description: "Fails", parameters: emptySchema) { _, _ in
    throw Failure.unavailable
  }
  let script = Script([
    .init(
      message: .assistant(
        "",
        toolCalls: [
          .init(id: "1", name: "unknown", arguments: "{}"),
          .init(id: "2", name: "fail", arguments: "{bad"),
          .init(id: "3", name: "fail", arguments: "{}"),
          .init(id: "4", name: "fail", arguments: "null"),
        ]), finishReason: "tool_calls"),
    .init(message: .assistant("I could not complete those tools.")),
  ])
  let (result, _) = try await drain(
    try Agent(tools: [tool]).run(
      Model("test", provider: ScriptedProvider(script: script)), messages: []))
  let results = result.messages[1].toolResults
  #expect(results.count == 4)
  #expect(results.allSatisfy { $0.isError })
  #expect(results.map(\.callID) == ["1", "2", "3", "4"])
}

// @lat: [[tests#Behavior specifications#Agent behavior#Subagent isolation]]
@Test func subagentStreamsAndReturnsFinalTextWithSeparateHistory() async throws {
  let childScript = Script([
    .init(
      message: .assistant(
        "Looking up Mars",
        toolCalls: [
          .init(id: "fact", name: "facts", arguments: "{}")
        ]), finishReason: "tool_calls"),
    .init(message: .assistant("Mars has two moons.")),
  ])
  let facts = Tool(name: "facts", description: "Facts", parameters: emptySchema) { _, _ in
    .string("Two moons")
  }
  let child = try Agent(tools: [facts])
  let parentScript = Script([
    .init(
      message: .assistant(
        "",
        toolCalls: [
          .init(id: "research1", name: "research", arguments: "{\"prompt\":\"Mars\"}")
        ]), finishReason: "tool_calls"),
    .init(message: .assistant("The researcher found two moons.")),
  ])
  let parent = try Agent(tools: [
    child.asTool(
      name: "research", description: "Research",
      model: Model("child", provider: ScriptedProvider(script: childScript)),
      instructions: "Be concise")
  ])
  let (result, events) = try await drain(
    parent.run(
      Model("parent", provider: ScriptedProvider(script: parentScript)),
      messages: [.user("Parent question")]))
  #expect(
    events.contains(
      .subagentEvent(toolCallID: "research1", event: .textDelta("Mars has two moons."))))
  let toolResult = result.messages[2].toolResults[0]
  #expect(toolResult.value == .string("Mars has two moons."))
  #expect(toolResult.subagentMessages?.last?.text == "Mars has two moons.")
  let requests = await childScript.requests
  #expect(requests[0].messages == [.system("Be concise"), .user("Mars")])
  #expect(result.messages.count == 4)
}

actor ConcurrencyProbe {
  var active = 0
  var peak = 0
  func enter() {
    active += 1
    peak = max(peak, active)
  }
  func leave() { active -= 1 }
}

// @lat: [[tests#Behavior specifications#Agent behavior#Bounded concurrency]]
@Test func toolConcurrencyIsBoundedAndHistoryKeepsCallOrder() async throws {
  let probe = ConcurrencyProbe()
  let tool = Tool(name: "work", description: "Work", parameters: emptySchema) { _, context in
    await probe.enter()
    // Different completion order exercises stable history ordering.
    try await Task.sleep(for: .milliseconds(context.call.id == "0" ? 40 : 5))
    await probe.leave()
    return .string(context.call.id)
  }
  let calls = (0..<5).map { ToolCall(id: String($0), name: "work", arguments: "{}") }
  let script = Script([
    .init(message: .assistant("", toolCalls: calls), finishReason: "tool_calls"),
    .init(message: .assistant("Done")),
  ])
  let agent = try Agent(tools: [tool], maxConcurrentTools: 2)
  let (result, _) = try await drain(
    agent.run(Model("test", provider: ScriptedProvider(script: script)), messages: []))
  #expect(await probe.peak == 2)
  #expect(result.messages[1].toolResults.map(\.callID) == ["0", "1", "2", "3", "4"])
}

actor Flag {
  private(set) var value = false
  func set() { value = true }
}

// @lat: [[tests#Behavior specifications#Agent behavior#Step budget]]
@Test func stepLimitPreventsFurtherRequestsAndToolSideEffects() async throws {
  let flag = Flag()
  let tool = Tool(name: "work", description: "Work", parameters: emptySchema) { _, _ in
    await flag.set()
    return .null
  }
  let script = Script([
    .init(
      message: .assistant(
        "",
        toolCalls: [
          .init(id: "1", name: "work", arguments: "{}")
        ]), finishReason: "tool_calls")
  ])
  let run = try Agent(tools: [tool], maxSteps: 1).run(
    Model("test", provider: ScriptedProvider(script: script)), messages: [])
  await #expect(throws: AIError.stepLimitExceeded(1)) { try await drain(run) }
  #expect(await flag.value == false)
  #expect(await script.requests.count == 1)
}

// @lat: [[tests#Behavior specifications#Agent behavior#Truncated tool completion]]
@Test func refusesToolsFromTruncatedCompletion() async throws {
  let flag = Flag()
  let tool = Tool(name: "work", description: "Work", parameters: emptySchema) { _, _ in
    await flag.set()
    return .null
  }
  let script = Script([
    .init(
      message: .assistant(
        "",
        toolCalls: [
          .init(id: "1", name: "work", arguments: "{}")
        ]), finishReason: "length")
  ])
  await #expect(throws: AIError.self) {
    try await drain(
      try Agent(tools: [tool]).run(
        Model("test", provider: ScriptedProvider(script: script)), messages: []))
  }
  #expect(await flag.value == false)
}

// @lat: [[tests#Behavior specifications#Agent behavior#Invalid configuration]]
@Test func validatesAgentConfiguration() throws {
  let tool = Tool(name: "same", description: "", parameters: emptySchema) { _, _ in .null }
  #expect(throws: AIError.self) { try Agent(tools: [tool, tool]) }
  #expect(throws: AIError.self) { try Agent(maxSteps: 0) }
  #expect(throws: AIError.self) { try Agent(maxConcurrentTools: 0) }
}

// @lat: [[tests#Behavior specifications#Agent behavior#Nested cancellation]]
@Test func cancellingParentCancelsSubagentTool() async throws {
  let started = AsyncStream<Void>.makeStream()
  let cancelled = Flag()
  let slow = Tool(name: "slow", description: "Wait", parameters: emptySchema) { _, _ in
    started.continuation.yield(())
    do { try await Task.sleep(for: .seconds(30)) } catch {
      await cancelled.set()
      throw error
    }
    return .null
  }
  let childScript = Script([
    .init(
      message: .assistant(
        "",
        toolCalls: [
          .init(id: "slow1", name: "slow", arguments: "{}")
        ]), finishReason: "tool_calls")
  ])
  let child = try Agent(tools: [slow])
  let parentScript = Script([
    .init(
      message: .assistant(
        "",
        toolCalls: [
          .init(id: "child1", name: "child", arguments: "{\"prompt\":\"Wait\"}")
        ]), finishReason: "tool_calls")
  ])
  let parent = try Agent(tools: [
    child.asTool(
      name: "child", description: "Delegate",
      model: Model("child", provider: ScriptedProvider(script: childScript)))
  ])
  let run = parent.run(
    Model("parent", provider: ScriptedProvider(script: parentScript)), messages: [])
  defer {
    run.cancel()
    started.continuation.finish()
  }
  for await _ in started.stream { break }
  run.cancel()
  await #expect(throws: CancellationError.self) { try await run.result }
  // result waits for the structured tool task group to finish cancellation.
  #expect(await cancelled.value)
  #expect(await parentScript.requests.count == 1)
}

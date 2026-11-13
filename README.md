# AI for Swift

A small Swift port of the non-durable core of the adjacent `ai-python` framework.
Build basic agents that stream model responses, execute local tools, and delegate
to subagents. No third-party Swift package dependencies. Swift 6 language mode.

## Linux setup

This workspace's machine is x86-64 Omarchy (Arch Linux). Install:

```bash
sudo pacman -S --needed base-devel git libxml2-legacy util-linux-libs ncurses patchelf
yay -S --needed swift-bin
swift --version
```

`yay` is an Arch User Repository (AUR) helper, already available on this machine.
`swift-bin` is an AUR package; `pacman -S swift-bin` does not fetch it. The current
package recipe installs Swift 6.4.2, depends on `libxml2-legacy`, `util-linux-libs`,
and `ncurses`, and uses `patchelf` when packaging the upstream binaries for Arch.
`base-devel` provides the system compiler/linker tools. Swift includes its own
Clang, Swift Package Manager, and Swift Testing; a separate Clang install is not
required. Python 3 is needed only for the optional loopback HTTP integration tests.
The optional `python312` dependency is for the REPL, not builds or tests.

Sources: [AUR package](https://aur.archlinux.org/packages/swift-bin),
[Swift's official Linux installation guide](https://www.swift.org/install/linux/).

```bash
cd ai-swift
swift build
swift test
python3 scripts/test-http.py
```

The first test command runs offline unit tests. The Python script starts a local
HTTP server, runs the HTTP integration suite, and shuts the server down. It checks
incremental delivery before response completion, HTTP errors, and connection
cancellation. Neither test command calls a model or requires credentials.

## Provider choice

OpenAI's [official SDK list](https://developers.openai.com/api/docs/libraries)
lists Swift clients as community libraries, not official SDKs.
Anthropic's [general-purpose client SDKs](https://platform.claude.com/docs/en/cli-sdks-libraries/overview)
do not include Swift. It does offer an official
[Claude for Apple Foundation Models](https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/apple-foundation-models)
Swift integration, which depends on Apple's framework and is unsuitable for Linux.

This package therefore implements OpenAI Chat Completions over HTTP/SSE directly.
Its first target is [Vercel AI Gateway](https://vercel.com/docs/ai-gateway/sdks-and-apis/openai-chat-completions)
at `https://ai-gateway.vercel.sh/v1`, using `creator/model` identifiers. Other
servers implementing that protocol can use the same provider with a different
base URL. This does not implement OpenAI Responses or Anthropic Messages.

## Stream one model response

```swift
import AI

let model = try Model.gateway("anthropic/claude-sonnet-4.6")
let response = AI.stream(model, messages: [
    .system("Be concise."),
    .user("Why is the sky blue?"),
])
defer { response.cancel() }

for try await event in response {
    if case .textDelta(let text) = event {
        print(text, terminator: "")
    }
}
let final = try await response.result
print(final.text, final.usage)
```

`Model.gateway` reads `AI_GATEWAY_API_KEY`, or accepts `apiKey:` explicitly.
`AI.stream` makes one model request. Supplying tool definitions to it does not
execute tools. `Stream.result` can also be awaited directly when events are not
needed. If importing Foundation creates a `Stream` name collision, spell the
type `AI.Stream<ModelResponse>`.

## Tools and agents

```swift
struct WeatherInput: Decodable, Sendable {
    let city: String
}

let weather = Tool(
    name: "weather",
    description: "Get the weather for a city.",
    parameters: .object([
        "type": .string("object"),
        "properties": .object(["city": .object(["type": .string("string")])]),
        "required": .array([.string("city")]),
        "additionalProperties": .bool(false),
    ]),
    arguments: WeatherInput.self
) { input, context in
    // Call your actual local service here.
    .string("Sunny in \(input.city)")
}

let agent = try Agent(tools: [weather], maxSteps: 10, maxConcurrentTools: 4)
let run = agent.run(model, messages: [.user("What is the weather in Paris?")])
defer { run.cancel() }
for try await event in run {
    if case .textDelta(let text) = event { print(text, terminator: "") }
}
let result = try await run.result
print(result.output)
// Continue a conversation by passing result.messages to another run.
```

Tools are async `@Sendable` closures. Use actors for shared mutable state.
Schemas are explicit; `Decodable` validates Swift argument types. Full JSON
Schema constraint validation (for example string patterns) is not implemented;
validate domain constraints inside the closure. A raw `JSONValue` overload is
also available, and `JSONValue(encoding:)` accepts any `Encodable` tool result.

The agent waits for a complete model response, executes its calls concurrently
up to the configured limit, appends their results, and requests another response.
Tool-result events arrive in completion order; history preserves call order.
Unknown tools, invalid arguments, and thrown tool errors become error results
the model can handle. Model/transport errors stop the run. Cancellation propagates
instead of becoming a tool error. A token-limited or filtered response cannot
trigger tool execution. At the step limit the run throws, without executing that
last turn's tools. `maxSteps` counts model requests, including the final answer.

## Subagents

```swift
let specialist = try Agent(tools: [weather])
let parent = try Agent(tools: [specialist.asTool(
    name: "ask_weather_specialist",
    description: "Delegate weather questions.",
    model: model,
    instructions: "Use the weather tool and answer concisely."
)])
let run = parent.run(model, messages: [.user("Plan around today's Paris weather.")])
defer { run.cancel() }
for try await event in run {
    switch event {
    case .textDelta(let text): print(text, terminator: "")
    case .subagentEvent(let callID, .textDelta(let text)):
        print("[\(callID)] \(text)")
    default: break
    }
}
```

`asTool` accepts a `prompt` argument from the parent model. The child has its own
conversation, model, tools, and limits. Its final text becomes the tool result;
its full history is retained in `ToolResult.subagentMessages`, but is not sent
to the parent model. Events can nest recursively. Parent cancellation propagates
to children and their tools. For custom argument shapes, use `ToolContext.run`
inside a normal tool. Usage totals cover each agent's own model requests; inspect
nested `agentEnd` events for subagent usage.

## Run the example

Set `AI_GATEWAY_API_KEY` in your environment, then:

```bash
swift run agent-example 'Tell me about Mars.'
```

The example demonstrates parent → researcher → local facts tool → parent answer.
Override the model with `AI_MODEL`. For another compatible endpoint, set
`AI_BASE_URL` (including `/v1`), `AI_MODEL`, and optionally `AI_API_KEY`.

## Relationship to ai-python

The source study focused on `models/core/model.py`, `models/core/api.py`,
`agents/agent.py`, and the streaming, agent, and subagent guides/examples.

| Python primitive | Swift equivalent |
| --- | --- |
| `ai.Model`, provider | `Model`, `Provider` protocol |
| `ai.stream` | `AI.stream`, `Stream<ModelResponse>` |
| `ai.Agent(...).run` | `Agent(...).run`, `Stream<AgentResult>` |
| `@ai.tool` | `Tool` with schema and async closure |
| `ai.SubAgentTool` | `Agent.asTool` or `ToolContext.run` |
| `PartialToolCallResult` | `Event.subagentEvent` |
| Stream message/output/usage | Await `stream.result` |

`Message`, `ToolCall`, `ToolResult`, and results are plain `Codable` values.
Implement `Provider` to add a wire protocol or script a test. Implement
`HTTPTransport` to replace HTTP. Write a custom loop using `AI.stream` for
different orchestration; the built-in loop does not require inheritance.

Streams start eagerly and are single-consumer, with unbounded event buffering.
Consume them promptly. Use `defer { run.cancel() }` when breaking iteration early;
a plain `break` does not guarantee immediate cancellation. Async tools must
cooperate with task cancellation. Final results are available on success;
partial output on failure can be retained from events. SSE parsing handles UTF-8
and tool arguments split across chunks, CR/LF framing, and usage-only chunks.
It requires both a finish reason and `[DONE]`; incomplete streams throw.

Scope deliberately excludes durability, persistence services, hooks, MCP,
multimodal content, structured-output modes, provider-native tools, automatic
retries, and provider-specific reasoning controls. This is a focused port of the
core behavior, not complete API parity.

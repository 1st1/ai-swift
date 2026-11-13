# Architecture

The library separates model requests, event transport, and agent orchestration so applications can use each layer independently. Plain Swift values and async closures keep custom control flow outside a framework-specific DSL.

## Package boundaries

The package exports one library and one example executable, with no third-party Swift dependencies.

[[Package.swift]] defines the AI library, the agent-example executable, and the AITests target in Swift 6 language mode. Foundation provides serialization and HTTP; FoundationNetworking supplies the Linux networking implementation.

The port covers text and reasoning deltas, function calls, local tools, and subagents. It does not implement durability, persistence services, hooks, MCP, multimodal inputs, structured-output modes, automatic retries, or provider-native tools. See [[NOTICE]] for attribution to ai-python.

## Composition boundaries

A model identifies a provider and model ID; a stream performs one model turn; an agent owns the loop that executes tools and requests further turns.

[[Sources/AI/Stream.swift#Model]] holds an immutable identifier and a [[Sources/AI/Stream.swift#Provider]] implementation. The free [[Sources/AI/Stream.swift#stream]] function forwards messages, tool definitions, and options to that provider without executing tools.

[[Sources/AI/Agent.swift#Agent]] adds [[agents#Agents and tools#Conversation loop|conversation orchestration]]. Each run owns its history and tasks, allowing the same immutable agent configuration to serve independent conversations. Applications can implement custom loops using the single-turn primitive without subclassing the built-in agent.

[[Sources/AI/Transport.swift#HTTPTransport]] separates HTTP delivery from [[Sources/AI/OpenAICompatibleProvider.swift#OpenAICompatibleProvider|protocol translation]]. Tests replace either this transport or the whole provider; see [[development#Development#Test infrastructure]].

## Conversation data

Messages and results are Codable values, so callers can inspect, serialize, or continue a conversation without a persistence subsystem.

[[Sources/AI/Types.swift#Message]] holds a role, text, reasoning, tool calls, and tool results. A tool message may group several results; the provider expands them into separate wire messages. [[Sources/AI/Types.swift#ToolCall]] retains arguments as JSON text, allowing malformed model arguments to reach the agent's error handling instead of requiring valid JSON during streaming.

[[Sources/AI/Types.swift#ToolResult]] associates a JSON value and error flag with the original call ID and name. It can retain subagent history independently of the value sent to the parent model. [[Sources/AI/JSONValue.swift#JSONValue]] supports nulls, booleans, signed integers, floating-point numbers, strings, arrays, and objects; integer decoding precedes floating-point decoding to preserve representable integer precision.

[[Sources/AI/Types.swift#ModelResponse]] contains one assistant message, usage, and a finish reason. [[Sources/AI/Types.swift#AgentResult]] contains complete run history, the number of model turns, and usage from that agent's own turns. Its output is the last assistant message's text. Nested usage is available through child completion events, not added to the parent's total.

## Event vocabulary

Model events describe a single response; agent events describe steps, tool results, and nested execution without mixing child output into parent text.

[[Sources/AI/Types.swift#Event]] includes model start/end, text and reasoning deltas, tool-call fragments and assembled calls, step start/end, tool results, and agent completion. The recursive subagent event carries the parent tool-call ID and an enclosed event. Consumers can route nested output separately while retaining arbitrarily nested event structure.

The stream result is the authoritative final aggregate. Events also allow callers to retain partial output if a run fails; see [[streaming#Model streaming#Results and failures]].

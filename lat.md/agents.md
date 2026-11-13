# Agents and tools

An agent repeatedly streams a model response, executes its requested local tools, and feeds the results back until a response contains no tool calls.

## Conversation loop

Each model turn sees the accumulated history and the registered tool definitions; execution begins only after that turn's complete response is available.

[[Sources/AI/Agent.swift#Agent#run]] emits a step-start event, forwards model events, appends the assistant message, and adds that turn's usage. If there are no calls, it emits step-end and agent-end with the final [[Sources/AI/Types.swift#AgentResult]]. Otherwise it executes the calls, appends one grouped tool message, emits step-end, and starts another turn.

Returned history includes the input messages. Passing it to another run continues the conversation. Successful local execution does not finish a run: the model gets another turn to interpret the results. [[tests#Behavior specifications#Agent behavior#Tool round trip]] checks history, usage, output, and Codable round trips.

## Configuration and execution limits

Limits bound model requests and simultaneous local tool tasks. The loop refuses side effects when it cannot request the follow-up model turn.

[[Sources/AI/Agent.swift#Agent#init]] requires positive step and concurrency limits, unique nonempty tool names using the permitted ASCII letters, digits, hyphens, or underscores, and object parameter schemas. Names have a bounded length. The source constructor owns the default values.

[[Sources/AI/Agent.swift#Agent#run]] counts every model request toward the step limit, including the final answer. A final allowed turn without calls succeeds; a final allowed turn with calls throws a step-limit error before executing those calls. Calls from finish reasons other than stop or tool_calls are rejected, preventing truncated arguments from triggering tools. IDs must be nonempty and unique within the response.

[[Sources/AI/Agent.swift#Agent#execute]] schedules only up to the configured concurrency limit and adds work as tasks finish. Tool-result events arrive in completion order, but the history is reordered to match the original call list. See [[tests#Behavior specifications#Agent behavior#Bounded concurrency]] and [[tests#Behavior specifications#Agent behavior#Step budget]].

## Tool contracts and errors

A tool pairs an explicit JSON schema with an async Sendable closure; model-visible failures allow the next model turn to recover.

[[Sources/AI/Tool.swift#ToolDefinition]] contains the name, description, and parameter schema sent to the model. [[Sources/AI/Tool.swift#Tool]] accepts either raw JSON values or Decodable and Sendable argument types. Explicit schemas avoid reflection or macros; typed decoding checks Swift types, not every JSON Schema constraint. Domain validation belongs inside the closure.

[[Sources/AI/Agent.swift#Agent#execute]] rejects non-object arguments and converts unknown names, JSON decoding errors, and ordinary closure failures to error [[Sources/AI/Types.swift#ToolResult|results]]. The provider serializes their values in an error object. Cancellation escapes this conversion and stops the run. Model and transport errors also stop the run rather than becoming local tool failures.

[[Sources/AI/Tool.swift#ToolContext]] exposes the current call and history to the closure. Shared mutable application state should use actors or other Sendable-safe synchronization. See [[tests#Behavior specifications#Agent behavior#Recoverable tool errors]].

## Subagent delegation

A child agent is a regular agent run inside a tool, with its own history and limits; only its final answer becomes the parent model's tool input.

[[Sources/AI/Agent.swift#Agent#asTool]] creates a tool accepting a prompt string. It builds a child conversation from optional system instructions and that prompt, using the captured child model and options. The child's final text is the tool value, and its history is retained in [[Sources/AI/Types.swift#ToolResult#subagentMessages]]. The provider does not send that nested history to the parent model.

[[Sources/AI/Tool.swift#ToolContext#run]] forwards each child event inside a subagent event tagged with the parent's call ID. Custom tools can call it with their own message construction; unlike the built-in adapter, they choose what to return and do not automatically retain child history. Recursion uses the same mechanism at every level.

Each agent enforces its own step and concurrency budgets; there is no global recursion or aggregate budget. Child failures propagate through the tool closure and ordinarily become parent tool errors, while cancellation propagates through the task tree. See [[tests#Behavior specifications#Agent behavior#Subagent isolation]] and [[streaming#Model streaming#Cancellation propagation]].

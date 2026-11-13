# Model streaming

Single-turn streaming exposes model output as it arrives and produces one final assistant response. It is the shared primitive for direct model access and the agent loop.

## Model selection and requests

Model selection is explicit: callers supply a provider or use the Gateway convenience constructor.

[[Sources/AI/Stream.swift#Model#gateway]] uses an explicit API key or the AI_GATEWAY_API_KEY environment variable and rejects missing or empty credentials. It constructs the [[provider#Chat Completions provider|Chat Completions provider]] with the Gateway base URL. Model identifiers pass through unchanged; there is no model registry or capability lookup.

[[Sources/AI/Stream.swift#ModelRequest]] carries the model ID, messages, tool definitions, and [[Sources/AI/Stream.swift#ModelOptions]]. Options expose temperature, a completion-token limit, and whether to request usage. The free [[Sources/AI/Stream.swift#stream]] function makes one provider call; tool definitions advertise capabilities but do not execute functions. [[tests#Behavior specifications#Agent behavior#Direct streaming]] protects this separation.

## Stream ownership

A stream starts eagerly, has a single event consumer, and exposes its final result separately from iteration.

[[Sources/AI/Stream.swift#Stream]] owns a producer task and an AsyncThrowingStream with unbounded buffering. The producer can run ahead of the consumer, and callers may await the result without consuming events. Consumers should read promptly because queued events are not subject to backpressure.

Callers that may stop iteration early should arrange explicit cancellation, usually with a defer statement. A plain break does not guarantee immediate producer shutdown. Dropping the stream also cancels its producer task.

## Results and failures

Successful completion finishes event delivery and makes the aggregate available; failure throws rather than returning a partial aggregate as success.

[[Sources/AI/Stream.swift#Stream#result]] awaits the producer task. The same producer error is forwarded to event iteration. When the producer is cancelled, its failure is normalized to CancellationError. Callers needing partial text or messages after a failure must retain them from [[architecture#Architecture#Event vocabulary|events]].

The built-in provider requires a complete wire response before returning [[Sources/AI/Types.swift#ModelResponse]]. Receiving text alone is insufficient; see [[provider#Chat Completions provider#Completion integrity]].

## Cancellation propagation

Cancellation flows from a run to its model request, child agents, and cooperative local tools, preventing cancellation from becoming a recoverable tool result.

[[Sources/AI/Stream.swift#Stream#cancel]] cancels the producer task. Cancellation while awaiting the result or cancelling event iteration also cancels that task. [[Sources/AI/Agent.swift#Agent#run]] explicitly cancels its active model stream; [[Sources/AI/Tool.swift#ToolContext#run]] does the same for its child stream.

Tool task groups wait for their tasks to finish, so user closures must cooperate with Swift task cancellation. The default [[Sources/AI/Transport.swift#URLSessionTransport#send|HTTP transport]] invalidates its session when delivery terminates. Coverage includes [[tests#Behavior specifications#Agent behavior#Nested cancellation]] and [[tests#Behavior specifications#HTTP behavior#Connection cancellation]].

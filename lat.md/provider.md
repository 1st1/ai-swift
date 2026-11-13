# Chat Completions provider

The built-in provider translates the library's values to OpenAI-compatible Chat Completions HTTP requests and incremental SSE responses, with Vercel AI Gateway as its convenience endpoint.

## Request translation

Protocol translation stays inside the provider so the agent loop and tools do not depend on a particular HTTP service.

[[Sources/AI/OpenAICompatibleProvider.swift#OpenAICompatibleProvider#init]] accepts an HTTP or HTTPS base URL without user credentials, query, or fragment, and a positive timeout. An optional API key becomes a Bearer header. [[Sources/AI/OpenAICompatibleProvider.swift#OpenAICompatibleProvider#makeRequest]] appends chat/completions and always requests a stream.

Messages carry role and text, optional reasoning_content, and assistant function calls. Grouped tool results become individual tool-role messages linked to their call IDs. String results are sent directly; other JSON values are serialized; error values are wrapped in an error object. Subagent history remains local.

Tool definitions become function schemas. Options map to temperature, max_completion_tokens, and optional usage reporting; positive token limits are checked locally. Other model-specific capabilities are not negotiated. This adapter does not implement Responses or Anthropic Messages. [[tests#Behavior specifications#Provider behavior#Request encoding]] checks the wire boundary.

## Incremental framing

SSE framing operates on bytes, preserving UTF-8 characters and JSON fragments that cross network chunk boundaries.

[[Sources/AI/SSE.swift#SSEParser#feed]] recognizes CR, LF, and CRLF line endings. [[Sources/AI/SSE.swift#SSEParser#finishLine]] strips an initial byte-order mark, joins data lines with newlines, dispatches on blank lines, and ignores comments and unrelated fields. Invalid UTF-8 and oversized frames fail rather than silently dropping content; [[Sources/AI/SSE.swift#SSEParser#maxEventBytes]] owns the frame-size limit.

[[Sources/AI/OpenAICompatibleProvider.swift#CompletionAccumulator#feed]] decodes chunks, forwards text and reasoning deltas, and accumulates tool fragments by their numeric index. It accepts usage-only chunks and uses their latest usage values. Tool IDs, names, and argument strings are assembled before completed calls are emitted. See [[tests#Behavior specifications#Provider behavior#Fragmented text and usage]] and [[tests#Behavior specifications#Provider behavior#Interleaved tool calls]].

## Completion integrity

Success requires a finish reason and the SSE DONE marker; partial text or a closed socket alone cannot establish a complete response.

[[Sources/AI/OpenAICompatibleProvider.swift#OpenAICompatibleProvider#stream]] throws an incomplete-response error if the transport ends before DONE. On DONE, [[Sources/AI/OpenAICompatibleProvider.swift#CompletionAccumulator#finish]] requires a finish reason, validates tool identities, orders calls by index, and emits completed tool-call events before the stream-end event.

The accumulator supports only choice index zero, rejects choices arriving after a finish reason, and rejects a tool_calls finish reason with no calls. Malformed JSON and in-band error payloads fail the stream. Tool argument JSON is left for local tool execution to decode, enabling [[agents#Agents and tools#Tool contracts and errors|model-visible argument errors]].

When no usage is reported, totals remain zero rather than being estimated. Completion does not promise an unrestricted natural-language answer: finish reasons remain visible to callers, and the agent applies additional restrictions before running tools. See [[tests#Behavior specifications#Provider behavior#Missing finish reason]] and [[tests#Behavior specifications#Provider behavior#Invalid completion]].

## HTTP delivery and failures

URLSession delegate callbacks deliver chunks on Linux without waiting for the full body. Session cleanup is tied to stream termination.

[[Sources/AI/Transport.swift#URLSessionTransport#send]] creates an ephemeral session with cookie and credential storage disabled. [[Sources/AI/Transport.swift#StreamingDelegate]] forwards status and data, surfaces transport failures, and refuses redirects so credentials are not forwarded to a new location.

[[Sources/AI/OpenAICompatibleProvider.swift#OpenAICompatibleProvider#stream]] requires a status before body data. Non-success responses become [[Sources/AI/Types.swift#AIError|HTTP errors]] with status and a bounded body excerpt. It performs no automatic retries. Cancellation invalidates the session and closes active delivery, as checked by [[tests#Behavior specifications#HTTP behavior#Connection cancellation]].

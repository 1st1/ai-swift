# AI for Swift

AI for Swift implements the non-durable core of ai-python: model streaming, local tool execution, and nested agents. This graph describes the implemented contracts and the tests that protect them.

- [[architecture]] — package boundaries, composition, and serializable data.
- [[streaming]] — single-turn requests, event delivery, results, and cancellation.
- [[agents]] — the agent loop, execution limits, tool errors, and subagents.
- [[provider]] — request translation, SSE framing, completion rules, and HTTP transport.
- [[tests]] — existing test coverage, linked back from test code.
- [[development]] — build commands, fixture infrastructure, and the runnable example.

For API usage examples and installation instructions, see [[README.md]]. These documents describe current behavior rather than a roadmap or complete Python API parity.

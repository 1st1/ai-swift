import Foundation
import Testing

@testable import AI

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite(.enabled(if: ProcessInfo.processInfo.environment["AI_HTTP_FIXTURE_URL"] != nil))
struct HTTPIntegration {
  var root: URL { URL(string: ProcessInfo.processInfo.environment["AI_HTTP_FIXTURE_URL"]!)! }

  // @lat: [[tests#Behavior specifications#HTTP behavior#Incremental network delivery]]
  @Test func receivesDeltaBeforeServerFinishesResponse() async throws {
    let provider = try OpenAICompatibleProvider(
      baseURL: root.appendingPathComponent("v1"), timeout: 15)
    let run = stream(Model("stream", provider: provider), messages: [.user("Hi")])
    defer { run.cancel() }
    var text = ""
    for try await event in run {
      if case .textDelta(let delta) = event {
        text += delta
        if delta == "early 🌍" {
          // The server sends the rest only after this acknowledgement.
          _ = try await URLSession.shared.data(from: root.appendingPathComponent("release"))
        }
      }
    }
    #expect(text == "early 🌍 late")
    #expect(try await run.result.text == text)
  }

  // @lat: [[tests#Behavior specifications#HTTP behavior#Network error response]]
  @Test func returnsHTTPFailure() async throws {
    let provider = try OpenAICompatibleProvider(baseURL: root.appendingPathComponent("v1"))
    await #expect(throws: AIError.http(status: 401, body: "{\"error\":\"fixture unauthorized\"}")) {
      try await drain(stream(Model("http-error", provider: provider), messages: []))
    }
  }

  // @lat: [[tests#Behavior specifications#HTTP behavior#Connection cancellation]]
  @Test func cancellationClosesNetworkConnection() async throws {
    let provider = try OpenAICompatibleProvider(
      baseURL: root.appendingPathComponent("v1"), timeout: 15)
    let run = stream(Model("cancel", provider: provider), messages: [])
    defer { run.cancel() }
    for try await event in run {
      if case .textDelta = event {
        run.cancel()
        break
      }
    }
    await #expect(throws: CancellationError.self) { try await run.result }
    for _ in 0..<100 {
      let (data, _) = try await URLSession.shared.data(
        from: root.appendingPathComponent("cancelled"))
      if try JSONDecoder().decode(JSONValue.self, from: data)["cancelled"] == .bool(true) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Cancelling the stream did not close its HTTP connection.")
  }
}

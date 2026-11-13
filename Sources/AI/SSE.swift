import Foundation

/// Byte-oriented framing preserves UTF-8 characters split between network chunks.
struct SSEParser {
  private var line: [UInt8] = []
  private var dataLines: [String] = []
  private var eventBytes = 0
  private var previousWasCR = false
  private var firstLine = true
  private let maxEventBytes = 1_048_576

  mutating func feed(_ data: Data) throws -> [String] {
    var events: [String] = []
    for byte in data {
      if byte == 10, previousWasCR {
        previousWasCR = false
        continue
      }
      previousWasCR = byte == 13
      if byte == 10 || byte == 13 {
        if let event = try finishLine() { events.append(event) }
      } else {
        line.append(byte)
        guard line.count + eventBytes <= maxEventBytes else {
          throw AIError.invalidResponse("SSE event exceeds 1 MiB.")
        }
      }
    }
    return events
  }

  private mutating func finishLine() throws -> String? {
    guard var text = String(bytes: line, encoding: .utf8) else {
      throw AIError.invalidResponse("SSE contains invalid UTF-8.")
    }
    line.removeAll(keepingCapacity: true)
    if firstLine {
      firstLine = false
      if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    }
    if text.isEmpty {
      defer {
        dataLines.removeAll(keepingCapacity: true)
        eventBytes = 0
      }
      return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
    }
    if text == "data" {
      eventBytes += 1
      guard eventBytes <= maxEventBytes else {
        throw AIError.invalidResponse("SSE event exceeds 1 MiB.")
      }
      dataLines.append("")
    } else if text.hasPrefix("data:") {
      var value = String(text.dropFirst(5))
      if value.hasPrefix(" ") { value.removeFirst() }
      eventBytes += value.utf8.count + 1
      guard eventBytes <= maxEventBytes else {
        throw AIError.invalidResponse("SSE event exceeds 1 MiB.")
      }
      dataLines.append(value)
    }
    return nil
  }
}

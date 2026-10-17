import Foundation

public enum APIError: Error, Sendable, Equatable {
  case unauthorized(String)
  case forbidden(String)
  case rateLimited(String)
  case server(String)
  case transport(String)
  case invalidResponse(String)

  public static func status(_ status: Int, body: String) -> APIError {
    switch status {
    case 401: .unauthorized(body)
    case 403: .forbidden(body)
    case 402, 429: .rateLimited(body)
    case 500...599: .server(body)
    default: .invalidResponse(body)
    }
  }

  public var isTransient: Bool {
    switch self {
    case .server, .transport, .rateLimited: true
    default: false
    }
  }
}

public struct UserError: Error, Sendable, Equatable, Codable {
  public var message: String
  public var retry: Bool

  public init(message: String, retry: Bool) {
    self.message = Self.sanitize(message)
    self.retry = retry
  }

  public init(_ error: APIError) {
    switch error {
    case .unauthorized, .forbidden:
      self.init(message: "The Sarvam key was refused. Open Settings and check it.", retry: false)
    case .rateLimited:
      self.init(message: "Sarvam is out of credits or rate limited.", retry: true)
    case .server:
      self.init(message: "Sarvam is having trouble. Retry in a moment.", retry: true)
    case .transport:
      self.init(message: "Connection lost - Retry", retry: true)
    case .invalidResponse(let detail):
      self.init(
        message: detail.isEmpty ? "Sarvam returned an invalid response." : detail, retry: false)
    }
  }

  public static func sanitize(_ raw: String) -> String {
    var value = raw
    let patterns = [
      #"sk-[A-Za-z0-9_-]+"#,
      #"\*{3,}[A-Za-z0-9_-]*"#,
      #"\b[A-Za-z0-9_\-]{24,}\b"#,
      #"[\{\}\[\]]"#,
    ]
    for pattern in patterns {
      value = value.replacingOccurrences(
        of: pattern, with: "[redacted]", options: .regularExpression)
    }
    value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(value.prefix(80))
  }
}

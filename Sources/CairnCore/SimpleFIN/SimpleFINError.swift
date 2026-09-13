import Foundation

/// Errors surfaced by the SimpleFIN client. Cases map to the protocol's
/// documented HTTP responses so the UI can give specific, actionable guidance.
public enum SimpleFINError: Error, LocalizedError, Sendable {
    /// The setup token was not a valid Base64-encoded URL.
    case invalidToken
    /// The claim URL was not HTTPS.
    case insecureURL
    /// `POST /claim/:token` returned 403 — used or compromised token.
    case claimForbidden
    /// `GET /accounts` returned 403 — access revoked or credentials invalid.
    case unauthorized
    /// `GET /accounts` returned 402 — the Bridge subscription needs attention.
    case paymentRequired
    case httpStatus(Int)
    case transport(String)
    case decoding(String)
    /// The server reported structured errors in `errlist`.
    case serverReported([SimpleFINServerError])

    public var errorDescription: String? {
        switch self {
        case .invalidToken:
            "That setup token could not be read. Copy the whole token from SimpleFIN and try again."
        case .insecureURL:
            "SimpleFIN returned an insecure (non-HTTPS) address. Cairn refused to use it."
        case .claimForbidden:
            "This setup token has already been used. If that wasn’t you, disable it at your SimpleFIN Bridge immediately, then create a new one."
        case .unauthorized:
            "Access was revoked or the credentials are no longer valid. Reconnect this institution to continue."
        case .paymentRequired:
            "Your SimpleFIN Bridge subscription needs attention. Cairn can’t fetch data until it’s resolved."
        case let .httpStatus(status):
            "The SimpleFIN server returned an unexpected response (HTTP \(status))."
        case let .transport(message):
            "Couldn’t reach the SimpleFIN server: \(ErrorSanitizer.sanitize(message))"
        case let .decoding(message):
            "The SimpleFIN server sent data Cairn couldn’t understand: \(ErrorSanitizer.sanitize(message))"
        case let .serverReported(errors):
            errors.first?.message ?? "The SimpleFIN server reported an error."
        }
    }
}

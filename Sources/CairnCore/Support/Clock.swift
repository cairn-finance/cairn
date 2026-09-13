import Foundation

/// Injectable time source so rate-budget and matching logic can be tested
/// deterministically.
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock, Sendable {
    public init() {}
    public var now: Date { Date() }
}

public struct FixedClock: Clock, Sendable {
    public let now: Date
    public init(now: Date) { self.now = now }
}

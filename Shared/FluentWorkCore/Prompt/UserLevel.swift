import Foundation

/// CEFR-style speaking level injected into the V2.0 system prompt (I20 T-I20-3).
///
/// Persistence and API fetch stay outside the builder. Callers read this from
/// settings / UserDefaults / profile and pass it in.
public enum UserLevel: String, Equatable, Sendable, Codable, CaseIterable {
    case beginner
    case intermediate
    case advanced
}

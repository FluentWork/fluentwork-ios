import Foundation

public enum SharedSchemaMirror: String, CaseIterable, Sendable {
    case wssControlFramesV2 = "wss-control-frames-v2"
    case speechObservabilityEventsV1 = "speech-observability-events-v1"

    public func data() throws -> Data {
        let directURL = Bundle.module.url(forResource: rawValue, withExtension: "json")
        let nestedURL = Bundle.module.url(
            forResource: rawValue,
            withExtension: "json",
            subdirectory: "Schemas"
        )
        guard let url = directURL ?? nestedURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}

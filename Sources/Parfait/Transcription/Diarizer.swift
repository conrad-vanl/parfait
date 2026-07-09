import FluidAudio
import Foundation

enum Diarizer {
    static func diarize(fileURL: URL, maxSpeakers: Int? = nil) async throws -> [DiarizedTurn] {
        // OfflineDiarizerManager is non-Sendable: create + use within this scope only.
        // Capping to the known remote-attendee count keeps VBx from fragmenting one
        // speaker into several across a noisy call (the system channel never carries
        // the local mic speaker, so this can't accidentally cap them out).
        var config = OfflineDiarizerConfig.default
        if let maxSpeakers, maxSpeakers > 0 {
            config = config.withSpeakers(max: maxSpeakers)
        }
        let manager = OfflineDiarizerManager(config: config)
        // First run downloads ~22 MB of Core ML models from HuggingFace; cached after.
        try await manager.prepareModels()
        let result = try await manager.process(fileURL)
        return result.segments
            .map {
                DiarizedTurn(
                    speaker: $0.speakerId,
                    start: TimeInterval($0.startTimeSeconds),
                    end: TimeInterval($0.endTimeSeconds)
                )
            }
            .sorted { $0.start < $1.start }
    }
}

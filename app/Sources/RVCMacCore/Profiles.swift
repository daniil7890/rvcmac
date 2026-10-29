import Foundation

/// A saved voice setup: model plus every processing parameter. Devices are not part of a profile.
public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var voice: String
    public var blockMs: Int
    public var extraMs: Int
    public var crossfadeMs: Int
    public var compute: String
    public var pitch: Double
    public var gateDB: Double
    public var gain: Double
    public var indexRatio: Double
    public var protect: Double

    public init(id: UUID = UUID(), name: String, voice: String, blockMs: Int, extraMs: Int, crossfadeMs: Int, compute: String,
                pitch: Double, gateDB: Double, gain: Double, indexRatio: Double, protect: Double) {
        self.id = id; self.name = name; self.voice = voice
        self.blockMs = blockMs; self.extraMs = extraMs; self.crossfadeMs = crossfadeMs; self.compute = compute
        self.pitch = pitch; self.gateDB = gateDB; self.gain = gain; self.indexRatio = indexRatio; self.protect = protect
    }

    /// Settings that need different Core ML models (a restart or a model switch), as opposed to live parameters.
    public func needsReload(comparedTo other: Profile) -> Bool {
        voice != other.voice || latencyKey != other.latencyKey || compute != other.compute
    }

    public var latencyKey: String { "b\(blockMs)_e\(extraMs)_c\(crossfadeMs)" }
}

/// Profiles live in one JSON file so they are easy to back up or edit by hand.
public final class ProfileStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> [Profile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Profile].self, from: data)) ?? []
    }

    public func save(_ profiles: [Profile]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(profiles).write(to: url, options: .atomic)
    }
}

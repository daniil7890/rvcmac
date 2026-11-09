import Accelerate
import CoreML
import Foundation
import RVCMacCore

package struct LatencyConfig: Codable, Hashable {
    package let key: String
    package let blockMs: Int
    package let extraMs: Int
    package let crossfadeMs: Int
    package let blockF: Int
    package let extraF: Int
    package let crossfadeF: Int
    package let solaF: Int
    package let F: Int
    package let skip: Int
    package let R: Int
    package let flowHead: Int
    package let decHead: Int
    package let N: Int
    package let E: Int
    package let synth: String
    package let shared: String
    /// Present for synth models that take features already upscaled to F frames (index-capable).
    package let phoneFrames: Int?

    package static func key(block: Int, extra: Int, crossfade: Int) -> String { "b\(block)_e\(extra)_c\(crossfade)" }
}

package struct IndexInfo: Codable, Hashable {
    package let file: String
    package let count: Int
    package let dim: Int
}

package struct VoiceInfo: Codable, Hashable {
    package let name: String
    package let version: String
    package let sr: Int
    package let embChannels: Int
    package let embOutput: String
    package let interChannels: Int?
    package let upp: Int?
    package let configs: [String: LatencyConfig]
    package let index: IndexInfo?
}

package struct FcpeMeta: Codable {
    package let f0Min: Double
    package let f0Max: Double
    package let outDims: Int
    package let frames: Int
    package let threshold: Double
}

package enum RVCMacPaths {
    /// Where voices, the converter environment, reports and settings files live:
    /// 1. Info.plist key RVCMacHome (local developer builds point it at the checkout),
    /// 2. ~/projects/rvcmac when it already holds voices from an older version (kept as is, nothing is moved),
    /// 3. otherwise ~/Library/Application Support/RVCMac.
    package static let home: URL = {
        let fm = FileManager.default
        if let s = Bundle.main.object(forInfoDictionaryKey: "RVCMacHome") as? String, !s.isEmpty {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RVCMac")
        let legacy = fm.homeDirectoryForCurrentUser.appendingPathComponent("projects/rvcmac")
        if !fm.fileExists(atPath: support.path) && fm.fileExists(atPath: legacy.appendingPathComponent("models/voices").path) {
            return legacy
        }
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }()
    package static var models: URL { home.appendingPathComponent("models") }
    package static var python: URL { home.appendingPathComponent("venv/bin/python") }

    /// The converter scripts: a checkout's own copy when present (development), otherwise the one inside the app.
    package static var converterDir: URL {
        let local = home.appendingPathComponent("converter")
        if FileManager.default.fileExists(atPath: local.appendingPathComponent("convert.py").path) { return local }
        return Bundle.main.resourceURL?.appendingPathComponent("converter") ?? local
    }
    package static var converter: URL { converterDir.appendingPathComponent("convert.py") }
    package static var requirements: URL { converterDir.appendingPathComponent("requirements.txt") }
}

package enum ModelLibrary {
    package static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    package static func voices() -> [VoiceInfo] {
        let dir = RVCMacPaths.models.appendingPathComponent("voices")
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("voice.json")) else { return nil }
            return try? decoder().decode(VoiceInfo.self, from: data)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    package static func voiceDir(_ v: VoiceInfo) -> URL {
        RVCMacPaths.models.appendingPathComponent("voices").appendingPathComponent(v.name)
    }

    /// Problems that would make a voice fail to load, in plain words (empty = looks fine).
    /// Only checks files and sizes; nothing from the model is executed.
    package static func validate(_ v: VoiceInfo) -> [String] {
        let fm = FileManager.default
        var issues: [String] = []
        let dir = voiceDir(v)
        if v.configs.isEmpty { issues.append(tr("нет собранных настроек задержки")) }
        var sharedChecked = Set<String>()
        for cfg in v.configs.values.sorted(by: { $0.key < $1.key }) {
            if !fm.fileExists(atPath: dir.appendingPathComponent(cfg.synth).path) {
                issues.append(trf("%@: нет %@", "\(cfg.key)", "\(cfg.synth)"))
            }
            if sharedChecked.insert(cfg.shared).inserted {
                let shared = RVCMacPaths.models.appendingPathComponent(cfg.shared)
                for f in ["embedder.mlpackage", "fcpe.mlpackage", "fcpe.json"] where !fm.fileExists(atPath: shared.appendingPathComponent(f).path) {
                    issues.append(trf("%@: нет общей модели %@/%@", "\(cfg.key)", "\(cfg.shared)", "\(f)"))
                }
            }
        }
        if let idx = v.index {
            let url = dir.appendingPathComponent(idx.file)
            let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int
            if size == nil {
                issues.append(trf("нет файла индекса %@", "\(idx.file)"))
            } else if size != idx.count * idx.dim * 4 {
                issues.append(trf("размер %@ не совпадает с voice.json", "\(idx.file)"))
            }
        }
        if ![256, 768].contains(v.embChannels) { issues.append(trf("неожиданная размерность признаков %@", "\(v.embChannels)")) }
        return issues
    }

    /// Compiles an .mlpackage once and caches the .mlmodelc next to it.
    static func compiled(_ package: URL) throws -> URL {
        let fm = FileManager.default
        let cached = package.deletingPathExtension().appendingPathExtension("mlmodelc")
        let pkgDate = (try? fm.attributesOfItem(atPath: package.appendingPathComponent("Manifest.json").path)[.modificationDate] as? Date) ?? .distantPast
        if fm.fileExists(atPath: cached.path),
           let cDate = try? fm.attributesOfItem(atPath: cached.path)[.modificationDate] as? Date, cDate >= pkgDate {
            return cached
        }
        let tmp = try MLModel.compileModel(at: package)
        if fm.fileExists(atPath: cached.path) { try fm.removeItem(at: cached) }
        try fm.moveItem(at: tmp, to: cached)
        return cached
    }

    static func load(_ package: URL, units: MLComputeUnits) throws -> MLModel {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        return try MLModel(contentsOf: compiled(package), configuration: cfg)
    }
}

/// Everything needed to run one voice at one latency config.
package final class LoadedVoice {
    package let voice: VoiceInfo
    package let config: LatencyConfig
    package let fcpe: FcpeMeta
    package let embedder: MLModel
    package let pitchModel: MLModel
    package let synth: MLModel
    package let upp: Int
    package let interChannels: Int
    /// Index vectors [count x dim] and their squared norms (nil when the voice has no index).
    package let indexVectors: [Float]?
    package let indexNorms: [Float]?

    package init(voice: VoiceInfo, config: LatencyConfig, units: MLComputeUnits) throws {
        self.voice = voice
        self.config = config
        let shared = RVCMacPaths.models.appendingPathComponent(config.shared)
        let metaData = try Data(contentsOf: shared.appendingPathComponent("fcpe.json"))
        fcpe = try ModelLibrary.decoder().decode(FcpeMeta.self, from: metaData)
        embedder = try ModelLibrary.load(shared.appendingPathComponent("embedder.mlpackage"), units: units)
        // FCPE runs in fp32: the Neural Engine is fp16-only, so keep it on GPU/CPU.
        pitchModel = try ModelLibrary.load(shared.appendingPathComponent("fcpe.mlpackage"),
                                           units: units == .cpuOnly ? .cpuOnly : .cpuAndGPU)
        synth = try ModelLibrary.load(ModelLibrary.voiceDir(voice).appendingPathComponent(config.synth), units: units)
        upp = voice.upp ?? voice.sr / 100
        interChannels = voice.interChannels ?? 192
        if let info = voice.index {
            let url = ModelLibrary.voiceDir(voice).appendingPathComponent(info.file)
            let data = try Data(contentsOf: url)
            let n = info.count * info.dim
            guard data.count == n * 4 else {
                throw NSError(domain: "RVCMac", code: 10, userInfo: [NSLocalizedDescriptionKey: "index.f32 has unexpected size"])
            }
            var vecs = [Float](repeating: 0, count: n)
            _ = vecs.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            var norms = [Float](repeating: 0, count: info.count)
            vecs.withUnsafeBufferPointer { v in
                for i in 0..<info.count {
                    var ss: Float = 0
                    vDSP_svesq(v.baseAddress! + i * info.dim, 1, &ss, vDSP_Length(info.dim))
                    norms[i] = ss
                }
            }
            indexVectors = vecs
            indexNorms = norms
        } else {
            indexVectors = nil
            indexNorms = nil
        }
    }
}

import CoreML

package enum ComputeChoice: String, CaseIterable, Identifiable {
    case neuralEngine = "Neural Engine + GPU"
    case aneOnly = "Neural Engine"
    case gpu = "GPU"
    case cpu = "CPU"
    package var id: String { rawValue }
    package var units: MLComputeUnits {
        switch self {
        case .neuralEngine: return .all
        case .aneOnly: return .cpuAndNeuralEngine
        case .gpu: return .cpuAndGPU
        case .cpu: return .cpuOnly
        }
    }
}

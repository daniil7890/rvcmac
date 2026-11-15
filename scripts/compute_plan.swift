import CoreML
import Foundation

// Dumps the per-device operation distribution of a Core ML model (MLComputePlan, macOS 14+).
// Usage: swift compute_plan.swift <model.mlpackage> [units: all|ane|gpu|cpu]
let path = CommandLine.arguments[1]
let unitsArg = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "all"
let cfg = MLModelConfiguration()
switch unitsArg {
case "ane": cfg.computeUnits = .cpuAndNeuralEngine
case "gpu": cfg.computeUnits = .cpuAndGPU
case "cpu": cfg.computeUnits = .cpuOnly
default: cfg.computeUnits = .all
}
let plan = try await MLComputePlan.load(contentsOf: URL(fileURLWithPath: path), configuration: cfg)
var counts: [String: Int] = [:]
var byOp: [String: [String: Int]] = [:]
func deviceName(_ d: MLComputeDevice?) -> String {
    guard let d else { return "unknown" }
    switch d {
    case .cpu: return "CPU"
    case .gpu: return "GPU"
    case .neuralEngine: return "ANE"
    @unknown default: return "other"
    }
}
func walkBlock(_ b: MLModelStructure.Program.Block) {
    for op in b.operations {
        let name = deviceName(plan.deviceUsage(for: op)?.preferred)
        counts[name, default: 0] += 1
        byOp[op.operatorName, default: [:]][name, default: 0] += 1
        for sub in op.blocks { walkBlock(sub) }
    }
}
switch plan.modelStructure {
case .program(let program):
    for (_, f) in program.functions { walkBlock(f.block) }
case .neuralNetwork:
    print("neuralNetwork structure — per-op plan not available")
@unknown default:
    print("unknown structure")
}
print("model: \(path) units: \(unitsArg)")
print("total ops by device: \(counts.sorted { $0.key < $1.key })")
for (op, devs) in byOp.sorted(by: { $0.key < $1.key }) {
    print("  \(op): \(devs.sorted { $0.key < $1.key })")
}
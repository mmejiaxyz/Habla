import Foundation
import COnnxRuntime

/// A small Swift layer over ONNX Runtime's C API: one session, CPU only, tensors in and out.
enum ONNXError: Error, CustomStringConvertible {
    case runtime(String)
    var description: String { if case .runtime(let s) = self { return "ONNX Runtime: \(s)" }; return "" }
}

/// One ONNX Runtime environment for the process (it owns the thread pools and the logger).
final class ORTEnvironment: @unchecked Sendable {
    static let shared = ORTEnvironment()
    let api: OrtApi
    let env: OpaquePointer

    private init() {
        guard let base = OrtGetApiBase(), let api = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            fatalError("ONNX Runtime \(ORT_API_VERSION) is not available")
        }
        self.api = api.pointee
        var env: OpaquePointer?
        let status = self.api.CreateEnv(ORT_LOGGING_LEVEL_ERROR, "habla", &env)
        precondition(status == nil && env != nil, "ONNX Runtime could not start")
        self.env = env!
    }

    func check(_ status: OpaquePointer?) throws {
        guard let status else { return }
        let message = api.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown error"
        api.ReleaseStatus(status)
        throw ONNXError.runtime(message)
    }
}

/// An input tensor; the data stays alive for the duration of `run`.
enum ONNXInput {
    case int64([Int64], shape: [Int64])
    case float([Float], shape: [Int64])
    case bool([Bool], shape: [Int64])
}

/// An output tensor, copied out of ONNX Runtime.
struct ONNXOutput {
    var shape: [Int64]
    var floats: [Float] = []
    var int64s: [Int64] = []
}

final class ONNXSession: @unchecked Sendable {
    private let ort = ORTEnvironment.shared
    private let session: OpaquePointer
    private let memory: OpaquePointer
    private let lock = NSLock()   // one run at a time per session

    init(modelData: Data, threads: Int = 1) throws {
        let ort = ORTEnvironment.shared
        let api = ort.api
        var options: OpaquePointer?
        try ort.check(api.CreateSessionOptions(&options))
        defer { api.ReleaseSessionOptions(options) }
        try ort.check(api.SetIntraOpNumThreads(options, Int32(threads)))
        try ort.check(api.SetInterOpNumThreads(options, 1))
        try ort.check(api.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))
        var session: OpaquePointer?
        try modelData.withUnsafeBytes { raw in
            try ort.check(api.CreateSessionFromArray(ort.env, raw.baseAddress, raw.count, options, &session))
        }
        var memory: OpaquePointer?
        try ort.check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory))
        self.session = session!
        self.memory = memory!
    }

    deinit {
        ort.api.ReleaseSession(session)
        ort.api.ReleaseMemoryInfo(memory)
    }

    /// Runs the graph. `inputs` are (name, tensor); `outputs` are the names to read back.
    func run(_ inputs: [(String, ONNXInput)], outputs: [String]) throws -> [ONNXOutput] {
        lock.lock(); defer { lock.unlock() }
        let api = ort.api
        var values: [OpaquePointer?] = []
        // Keep every input buffer alive until Run returns.
        var keep: [Any] = []
        defer { for v in values { api.ReleaseValue(v) } }

        for (_, input) in inputs {
            var value: OpaquePointer?
            switch input {
            case .int64(let data, let shape):
                let buf = UnsafeMutableBufferPointer<Int64>.allocate(capacity: max(1, data.count))
                _ = buf.initialize(from: data)
                keep.append(Deallocator(buf))
                try ort.check(api.CreateTensorWithDataAsOrtValue(memory, buf.baseAddress, data.count * 8, shape, shape.count,
                                                                 ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &value))
            case .float(let data, let shape):
                let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, data.count))
                _ = buf.initialize(from: data)
                keep.append(Deallocator(buf))
                try ort.check(api.CreateTensorWithDataAsOrtValue(memory, buf.baseAddress, data.count * 4, shape, shape.count,
                                                                 ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &value))
            case .bool(let data, let shape):
                let buf = UnsafeMutableBufferPointer<Bool>.allocate(capacity: max(1, data.count))
                _ = buf.initialize(from: data)
                keep.append(Deallocator(buf))
                try ort.check(api.CreateTensorWithDataAsOrtValue(memory, buf.baseAddress, data.count, shape, shape.count,
                                                                 ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL, &value))
            }
            values.append(value)
        }

        var results = [OpaquePointer?](repeating: nil, count: outputs.count)
        defer { for r in results { api.ReleaseValue(r) } }
        let inNames: [UnsafeMutablePointer<CChar>?] = inputs.map { strdup($0.0) }
        let outNames: [UnsafeMutablePointer<CChar>?] = outputs.map { strdup($0) }
        defer { (inNames + outNames).forEach { free($0) } }
        let inPtrs: [UnsafePointer<CChar>?] = inNames.map { UnsafePointer($0) }
        let outPtrs: [UnsafePointer<CChar>?] = outNames.map { UnsafePointer($0) }
        let inValues: [OpaquePointer?] = values
        let status: OpaquePointer? = api.Run(session, nil, inPtrs, inValues, inputs.count, outPtrs, outputs.count, &results)
        try ort.check(status)
        withExtendedLifetime(keep) {}

        return try results.map { value in
            var info: OpaquePointer?
            try ort.check(api.GetTensorTypeAndShape(value, &info))
            defer { api.ReleaseTensorTypeAndShapeInfo(info) }
            var rank = 0
            try ort.check(api.GetDimensionsCount(info, &rank))
            var shape = [Int64](repeating: 0, count: rank)
            try ort.check(api.GetDimensions(info, &shape, rank))
            var count = 0
            try ort.check(api.GetTensorShapeElementCount(info, &count))
            var type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
            try ort.check(api.GetTensorElementType(info, &type))
            var raw: UnsafeMutableRawPointer?
            try ort.check(api.GetTensorMutableData(value, &raw))
            var out = ONNXOutput(shape: shape)
            switch type {
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT:
                out.floats = Array(UnsafeBufferPointer(start: raw?.assumingMemoryBound(to: Float.self), count: count))
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64:
                out.int64s = Array(UnsafeBufferPointer(start: raw?.assumingMemoryBound(to: Int64.self), count: count))
            default:
                throw ONNXError.runtime("unexpected output type \(type.rawValue)")
            }
            return out
        }
    }
}

private final class Deallocator<T> {
    let buffer: UnsafeMutableBufferPointer<T>
    init(_ b: UnsafeMutableBufferPointer<T>) { buffer = b }
    deinit { buffer.deallocate() }
}

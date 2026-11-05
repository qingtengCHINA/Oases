import Foundation
import Metal

/// Host-side Metal bridge for the Linux agent.
///
/// iSH guest processes cannot import iOS frameworks directly. The viable
/// architecture is a native iOS tool that exposes selected GPU jobs to the
/// model/agent, while Linux remains the orchestration workspace.
final class MetalBridgeTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "metal_bridge",
        summary: """
        Inspect and exercise the native iOS Metal GPU bridge available to the device-local agent. \
        Use action=status to see GPU capabilities. Use action=vector_add_selftest to run a small Metal compute \
        kernel and verify that the host bridge can execute GPU work for the Linux/iSH agent. \
        iSH itself cannot directly import Metal; this tool is the supported host bridge.
        """,
        displayName: "Metal GPU",
        inputSchemaJSON: """
        {"type":"object","properties":{"action":{"type":"string","enum":["status","vector_add_selftest"],"default":"status"},"length":{"type":"integer","description":"Vector length for vector_add_selftest.","default":4096}}}
        """,
        surfaces: [.project],
        requiresPermission: false
    )

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let action = ((args["action"] as? String) ?? "status").trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case "vector_add_selftest":
            let length = max(1, min((args["length"] as? Int) ?? 4096, 1_000_000))
            let text = try await Self.runVectorAddSelfTest(length: length, onProgress: onProgress)
            return .textOnly(text)
        default:
            return .textOnly(Self.statusText())
        }
    }

    private static func statusText() -> String {
        #if targetEnvironment(simulator)
        return """
        Metal bridge unavailable on iOS Simulator.
        reason=simulator_metal_device_not_representative
        note=Run on a physical iPhone to verify host-side Metal GPU jobs for the iSH/Ogent agent.
        """
        #else
        guard let device = MTLCreateSystemDefaultDevice() else {
            return """
            Metal bridge unavailable.
            reason=MTLCreateSystemDefaultDevice returned nil
            """
        }

        var lines = [
            "Metal bridge available",
            "architecture=host-tool-for-ish-agent",
            "device=\(device.name)",
            "hasUnifiedMemory=\(device.hasUnifiedMemory)",
            "recommendedMaxWorkingSetSize=\(device.recommendedMaxWorkingSetSize)",
            "maxBufferLength=\(device.maxBufferLength)",
            "supportsDynamicLibraries=\(device.supportsDynamicLibraries)",
            "supportsRaytracing=\(device.supportsRaytracing)",
            "note=iSH Linux cannot directly import Metal; call this bridge for native GPU jobs."
        ]

        #if os(iOS)
        let families: [(MTLGPUFamily, String)] = [
            (.apple1, "apple1"), (.apple2, "apple2"), (.apple3, "apple3"), (.apple4, "apple4"),
            (.apple5, "apple5"), (.apple6, "apple6"), (.apple7, "apple7"), (.apple8, "apple8"),
            (.apple9, "apple9")
        ]
        let supported = families
            .filter { device.supportsFamily($0.0) }
            .map(\.1)
            .joined(separator: ",")
        lines.append("gpuFamilies=\(supported.isEmpty ? "unknown" : supported)")
        #endif

        return lines.joined(separator: "\n")
        #endif
    }

    private static func runVectorAddSelfTest(
        length: Int,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        #if targetEnvironment(simulator)
        return """
        Metal vector_add selftest skipped
        reason=simulator_metal_device_not_representative
        bridge=unavailable_on_simulator
        """
        #else
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return "Metal bridge unavailable."
        }

        onProgress("[metal] compile vector_add kernel\n")
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void vector_add(
            device const float *a [[buffer(0)]],
            device const float *b [[buffer(1)]],
            device float *out [[buffer(2)]],
            uint id [[thread_position_in_grid]]
        ) {
            out[id] = a[id] + b[id];
        }
        """
        let library = try await device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "vector_add") else {
            return "[metal error] vector_add function missing"
        }
        let pipeline = try await device.makeComputePipelineState(function: function)

        let byteCount = length * MemoryLayout<Float>.stride
        guard let a = device.makeBuffer(length: byteCount, options: .storageModeShared),
              let b = device.makeBuffer(length: byteCount, options: .storageModeShared),
              let out = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            return "[metal error] failed to allocate buffers"
        }

        let ap = a.contents().bindMemory(to: Float.self, capacity: length)
        let bp = b.contents().bindMemory(to: Float.self, capacity: length)
        for i in 0..<length {
            ap[i] = Float(i)
            bp[i] = Float(length - i)
        }

        onProgress("[metal] dispatch length=\(length)\n")
        let start = Date()
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return "[metal error] failed to create command encoder"
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(a, offset: 0, index: 0)
        encoder.setBuffer(b, offset: 0, index: 1)
        encoder.setBuffer(out, offset: 0, index: 2)

        let width = pipeline.threadExecutionWidth
        let threadsPerGroup = MTLSize(width: width, height: 1, depth: 1)
        let threads = MTLSize(width: length, height: 1, depth: 1)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        await commandBuffer.completed()

        if let error = commandBuffer.error {
            return "[metal error] \(error.localizedDescription)"
        }

        let elapsed = Date().timeIntervalSince(start)
        let outp = out.contents().bindMemory(to: Float.self, capacity: length)
        var failures = 0
        var checksum: Double = 0
        for i in 0..<length {
            let expected = Float(length)
            if outp[i] != expected { failures += 1 }
            checksum += Double(outp[i])
        }

        return """
        Metal vector_add selftest
        device=\(device.name)
        length=\(length)
        failures=\(failures)
        checksum=\(String(format: "%.1f", checksum))
        elapsed=\(String(format: "%.4fs", elapsed))
        bridge=ok
        """
        #endif
    }
}

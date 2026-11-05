import Foundation

/// OpenMinis-shaped facade over OasesChat's iSH runtime.
///
/// Ported OpenMinis sources call `ISHKernel.shared.*` extensively
/// (`AIChatViewModel`, `ISHExecutionCoordinator`, `MinisFsRouter`,
/// `MCPStore`, Rootfs terminal). OasesChat boots via
/// `ISHRuntimeBootstrap` + C bridges (`oases_bind_mount`,
/// `oases_install_path_translate_block`, …) rather than shipping the
/// full Objective-C `ISHKernel.m`. This adapter preserves the OpenMinis
/// call surface so those files compile and run against the Oases stack.
@objc(ISHKernel)
final class ISHKernel: NSObject {
    @objc static let shared = ISHKernel()

    private let lock = NSLock()
    private var booted = false
    private var rootPathCached: String?

    /// Matches OpenMinis `ISHKernel.outputCallback`.
    @objc var outputCallback: ((Data) -> Void)?

    /// Injected into shell executions (OpenMinis `customEnvironment`).
    @objc var customEnvironment: [String: String]?

    private override init() {
        super.init()
        // Reflect runtime state if bootstrap already ran.
        if ish_runtime_is_ready() != 0 {
            booted = true
        }
    }

    @objc var isBooted: Bool {
        lock.lock(); defer { lock.unlock() }
        if booted { return true }
        let ready = ish_runtime_is_ready() != 0
        if ready { booted = true }
        return ready
    }

    /// OpenMinis: `boot(withRootPath:)` → 0 on success.
    @objc(bootWithRootPath:)
    @discardableResult
    func boot(withRootPath rootPath: String) -> Int32 {
        lock.lock()
        if booted || ish_runtime_is_ready() != 0 {
            booted = true
            lock.unlock()
            return 0
        }
        lock.unlock()

        // Prefer the staged Oases rootfs; fall back to the path the caller
        // supplied (OpenMinis RootfsManager.dataPath). Staging and mounting
        // share ISHRootfsManager.bootLock with ISHRuntimeBootstrap.
        ISHRootfsManager.bootLock.lock()
        let path = ISHRootfsManager.stageBundledRootfsIfNeeded() ?? rootPath
        let code = ish_runtime_is_ready() != 0 ? 0 : path.withCString { ish_runtime_initialize($0) }
        ISHRootfsManager.bootLock.unlock()
        lock.lock()
        if code == 0 {
            booted = true
            rootPathCached = path
            // Offload registration is idempotent and required after boot.
            oases_offload_bootstrap()
        }
        lock.unlock()
        if code == 0 {
            OasesDnsBridge.shared.refreshIfAvailable()
        }
        return code
    }

    /// OpenMinis: start an interactive command argv (e.g. `["/bin/sh","-l"]`).
    @objc(executeCommand:)
    @discardableResult
    func executeCommand(_ command: [String]) -> Int32 {
        executeCommand(command, fsContext: 0)
    }

    /// Same, stamped with a session's fs_context so `/var/minis/{workspace,
    /// attachments,offloads,browser}` are that session's buckets — the files
    /// Ogent wrote — instead of the empty rootfs directories.
    @discardableResult
    func executeCommand(_ command: [String], fsContext: UInt64) -> Int32 {
        guard isBooted || boot(withRootPath: rootPathCached ?? ISHRootfsManager.dataURL.path) == 0 else {
            return -1
        }
        guard let exe = command.first else { return -1 }
        let args = Array(command.dropFirst())
        let env = customEnvironment
        let pid = ISHShellExecutor.executeExecutable(
            exe,
            arguments: args,
            environment: env,
            fsContext: fsContext,
            lineCallback: { [weak self] line, _ in
                guard let self, let cb = self.outputCallback else { return }
                if let data = (line + "\n").data(using: .utf8) {
                    cb(data)
                }
            },
            completion: nil
        )
        return Int32(pid)
    }

    @objc(sendInput:)
    func sendInput(_ data: Data) {
        // Interactive PTY input is owned by ISHTerminalView's session;
        // OpenMinis kernel sendInput feeds the primary shell. Forward via
        // notification so the active terminal can consume it.
        NotificationCenter.default.post(
            name: Notification.Name("ISHKernelSendInput"),
            object: nil,
            userInfo: ["data": data]
        )
    }

    @objc(sendInputString:)
    func sendInputString(_ input: String) {
        if let data = input.data(using: .utf8) {
            sendInput(data)
        }
    }

    @objc(setTerminalSize:rows:)
    func setTerminalSize(_ columns: Int32, rows: Int32) {
        NotificationCenter.default.post(
            name: Notification.Name("ISHKernelSetTerminalSize"),
            object: nil,
            userInfo: ["cols": columns, "rows": rows]
        )
    }

    @objc(bindMountPath:toHostPath:)
    @discardableResult
    func bindMountPath(_ linuxPath: String, toHostPath hostPath: String) -> Int32 {
        bindMountPath(linuxPath, toHostPath: hostPath, readOnly: false)
    }

    @objc(bindMountPath:toHostPath:readOnly:)
    @discardableResult
    func bindMountPath(_ linuxPath: String, toHostPath hostPath: String, readOnly: Bool) -> Int32 {
        // fakefs_bind_mount reads the kernel's thread-local `current` task.
        // Calling it from a Swift cooperative thread leaves that pointer null
        // and faults (EXC_BAD_ACCESS near a small offset such as 0x458).
        ISHRuntimeQueue.sync {
            guard self.isBooted || ISHRuntimeBootstrap.bootstrap() else { return Int32(-1) }
            return linuxPath.withCString { lp in
                hostPath.withCString { hp in
                    oases_bind_mount(lp, hp, readOnly ? 1 : 0)
                }
            }
        }
    }

    @objc(bindUnmountPath:)
    @discardableResult
    func bindUnmountPath(_ linuxPath: String) -> Int32 {
        ISHRuntimeQueue.sync {
            guard self.isBooted else { return Int32(-1) }
            return linuxPath.withCString { oases_unmount($0) }
        }
    }

    @objc func refreshDns() {
        OasesDnsBridge.shared.refreshIfAvailable()
    }

    // Path translate/reverse hooks are owned by `OasesFsRouter.installHookIfNeeded()`.
    // The OpenMinis wrappers that used to live here wrote the same single global
    // slot and would have silently replaced the router, so they were removed.
}

extension ISHKernel: @unchecked Sendable {}

import Foundation

enum ISHRuntimeBootstrap {
    nonisolated(unsafe) private static var didInstallGuestOgentAgent = false
    /// [Stage 0.4] True after `oases_offload_bootstrap()` has been called
    /// once this process. Calling the C entry repeatedly is safe (each
    /// `*_offload_register` overwrites its own slot), but we gate it to keep
    /// logs clean and to mirror the OpenMinis `ISHKernel` single-boot model
    /// where the register sequence runs as part of `become_first_process`.
    nonisolated(unsafe) private static var didRegisterOffloads = false

    /// Run the entire bootstrap. Returns true if the runtime is
    /// usable when the call ends. Safe to call repeatedly — only
    /// the first call does real work; subsequent ones return the
    /// cached `ish_runtime_is_ready()` value.
    @discardableResult
    static func bootstrap() -> Bool {
        if ish_runtime_is_ready() != 0 {
            registerOffloadsIfNeeded()
            return ensureGuestOgentAgent()
        }

        // Files written before the /var/oases buckets were unified with the
        // app's canonical trees; must move before the shell can look for them.
        OasesFsRouter.shared.migrateLegacyHostTrees()

        // Stage + mount under the shared boot lock; another path may have
        // booted the kernel while we waited for it.
        ISHRootfsManager.bootLock.lock()
        if ish_runtime_is_ready() == 0 {
            guard let rootfs = ISHRootfsManager.stageBundledRootfsIfNeeded() else {
                ISHRootfsManager.bootLock.unlock()
                NSLog("[ISHRuntime] rootfs staging failed; shell_local will return stub")
                return false
            }
            // The runtime expects the path to the data root (the dir
            // containing bin/, etc/, lib/, …). Pass the absolute path.
            let code = rootfs.withCString { ish_runtime_initialize($0) }
            if code != 0 {
                ISHRootfsManager.bootLock.unlock()
                NSLog("[ISHRuntime] init failed: code=\(code)")
                return false
            }
        }
        ISHRootfsManager.bootLock.unlock()
        guard ish_runtime_is_ready() != 0 else {
            return false
        }
        registerOffloadsIfNeeded()
        // NetworkMonitor may have fired before the kernel existed.
        OasesDnsBridge.shared.refreshIfAvailable()
        return ensureGuestOgentAgent()
    }

    /// Register the vendored NativeOffload handlers (openminis `ISHKernel.m`
    /// line 414-445). Must run after `ish_runtime_initialize` so the kernel's
    /// `native_offload_add_handler` registry mutex is initialized. Subsequent
    /// Stage 4 batches (Photos/Calendar/...) extend this same call
    /// site without re-touching `bootstrap()`.
    private static func registerOffloadsIfNeeded() {
        guard !didRegisterOffloads else { return }
        oases_offload_bootstrap()
        didRegisterOffloads = true
    }

    @discardableResult
    private static func ensureGuestOgentAgent() -> Bool {
        if didInstallGuestOgentAgent { return true }

        // Host-side writes into `data/` are only the cold-start staging
        // material. iSH's fakefs keeps names and metadata in meta.db, so a
        // regular host write is not visible to guest path lookup. Copy the
        // three runtime entrypoints through fakefs after the kernel is
        // mounted. This also avoids sending the full script through
        // `/bin/sh -c`, where the long argv has shown up as
        // `do_execve failed: -14`.
        ISHOgentAgentRuntime.install(into: ISHRootfsManager.dataURL)
        let fileNames = ["ogent-agent", "minis-agent", "oases-12306-mcp"]
        for fileName in fileNames {
            let hostURL = ISHRootfsManager.dataURL
                .appendingPathComponent("usr/local/bin", isDirectory: true)
                .appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: hostURL) else {
                NSLog("[ISHRuntime] guest install source missing: %@", hostURL.path)
                return false
            }
            let guestPath = "/usr/local/bin/\(fileName)"
            let result = data.withUnsafeBytes { bytes in
                ish_runtime_write_guest_file(
                    guestPath,
                    bytes.baseAddress,
                    data.count,
                    0o755
                )
            }
            guard result == 0 else {
                NSLog("[ISHRuntime] guest fakefs write failed: path=%@ code=%d", guestPath, result)
                return false
            }
        }

        // The rootfs data directory is host-visible, but fakefs directory
        // entries are stored separately in meta.db. Materialize the Ogent
        // roots before any shell-created workspace or persistent MCP session
        // tries to write below them.
        // OpenMinis-aligned agent tree (file tools + shell share these).
        _ = OasesPathResolver.materializeGuestLayout()

        let guestDirectories = [
            "/root/.ogent",
            "/root/.ogent/workspace",
            "/root/.ogent/tasks",
            "/root/.ogent/tasks/automations",
            "/root/.ogent/memory",
            "/root/.ogent/memory/wiki",
            "/root/.ogent/memory/wiki/topics",
            "/root/.ogent/skills",
            "/root/.ogent/subagents",
            "/root/.ogent/automations",
            "/root/.ogent/inbox",
            "/root/.ogent/artifacts",
            "/root/.ogent/logs",
            "/root/.ogent/tmp",
            "/root/.ogent/sessions",
            "/root/.ogent/project-manifests",
            "/root/.ogent/checkpoints",
            "/root/.ogent/env.d",
            "/root/.ogent/models",
            "/root/.ogent/models/bin",
            "/root/.ogent/rootfs-profiles",
            "/root/.ogent/mcp-sessions",
            // Canonical agent I/O (also created by OasesPathResolver; listed for
            // the bootstrap-check script visibility).
            "/var/oases",
            "/var/oases/workspace",
            "/var/oases/attachments",
            "/var/oases/offloads",
            "/var/oases/browser",
            "/var/oases/memory",
            "/var/oases/skills",
            "/var/oases/sessions",
            // Standard Alpine directories. git drops empty directories, so
            // rootfs trees staged from older bundles lost these rows on the
            // first mount; tools like apk, pip and ffmpeg expect them.
            "/tmp",
            "/var/tmp",
            "/var/cache/apk",
            "/home",
            "/run",
            "/opt"
        ]
        let guestLayout = guestDirectories.joined(separator: " ")
        NSLog("[ISHRuntime] materializing Ogent guest layout count=%ld", guestDirectories.count)
        for guestDirectory in guestDirectories {
            let result = guestDirectory.withCString { ish_runtime_ensure_guest_directory($0) }
            guard result == 0 else {
                NSLog("[ISHRuntime] guest directory create failed: path=%@ code=%d", guestDirectory, result)
                return false
            }
        }

        let command = """
        mkdir -p \(guestLayout) 2>&1 || { echo "ogent-layout-create-failed"; exit 70; }
        chmod 1777 /tmp /var/tmp 2>/dev/null || true
        for guest_path in \(guestLayout); do
          test -d "$guest_path" || { echo "ogent-layout-missing:$guest_path"; exit 71; }
        done
        ls -ld /usr/local /usr/local/bin /usr/local/bin/ogent-agent 2>&1 || true
        ls -ld /root /root/.ogent /root/.ogent/workspace /root/.ogent/artifacts /root/.ogent/mcp-sessions 2>&1 || true
        wc -c /usr/local/bin/ogent-agent 2>&1 || true
        test -e /usr/local/bin/ogent-agent || { echo "ogent-agent missing"; exit 66; }
        test -x /usr/local/bin/ogent-agent || { echo "ogent-agent not executable"; exit 67; }
        test -d /root/.ogent || { echo "ogent-root missing"; exit 68; }
        test -d /root/.ogent/mcp-sessions || { echo "ogent-mcp-sessions missing"; exit 69; }
        /bin/sh /usr/local/bin/ogent-agent bootstrap-check >/dev/null
        """
        let result = ISHShellExecutor.executeCommandSync(
            command,
            timeout: 45,
            lineCallback: nil
        )
        if result.exitCode == 0 {
            didInstallGuestOgentAgent = true
            return true
        }

        NSLog("[ISHRuntime] ogent-agent guest install failed: exit=\(result.exitCode) stdout=\(result.output) stderr=\(result.errorOutput)")
        return false
    }
}

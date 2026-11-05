import Foundation

private let mountApplyLog = AppLogger(category: "ExternalMounts")

/// Applies the user's mounted folders into the guest filesystem.
///
/// Ported from OpenMinis `ISHExecutionCoordinator`'s external-mount half.
/// `MountedFoldersManager` owns the security-scoped bookmarks and decides
/// *what* should be mounted; this type owns *applying* that to iSH via
/// `oases_bind_mount` / `oases_unmount`.
///
/// Both calls must run on the dedicated iSH runtime thread, hence the
/// `ISHRuntimeQueue` hops.
struct ExternalMountSpec: Equatable, Sendable {
    /// Guest path, e.g. `/var/oases/mounts/Documents`.
    let linuxDir: String
    /// Host path resolved from the security-scoped bookmark.
    let hostPath: String
    let readOnly: Bool
}

final class OasesExternalMountsManager: @unchecked Sendable {
    static let shared = OasesExternalMountsManager()

    /// Guest directory the mounts live under. `/var/minis/mounts` in OpenMinis.
    static let mountsLinuxDir = "\(OasesPathResolver.guestBase)/mounts"

    private let lock = NSLock()
    /// Last snapshot successfully applied, so reconciliation only touches deltas.
    private var applied: [String: ExternalMountSpec] = [:]
    /// Desired state, written by `MountedFoldersManager` on the main actor and
    /// read from the runtime thread — hence the lock rather than an actor.
    private var desired: [ExternalMountSpec] = []

    private init() {}

    /// Record what *should* be mounted. Cheap and synchronous so the settings
    /// UI can call it from the main actor without an await.
    func setSnapshot(_ specs: [ExternalMountSpec]) {
        lock.lock()
        desired = specs
        lock.unlock()
        mountApplyLog.info("snapshot set count=\(specs.count)")
    }

    func currentSnapshot() -> [ExternalMountSpec] {
        lock.lock(); defer { lock.unlock() }
        return desired
    }

    /// Reconcile guest mounts against the desired snapshot. No-op when the
    /// runtime isn't up yet — `MountedFoldersManager` re-applies after boot.
    func apply() {
        guard ISHRuntimeQueue.sync({ ISHRuntimeBootstrap.bootstrap() }) else {
            mountApplyLog.info("apply skipped — iSH runtime not ready")
            return
        }

        lock.lock()
        let want = desired
        let have = applied
        lock.unlock()

        let wantByDir = Dictionary(uniqueKeysWithValues: want.map { ($0.linuxDir, $0) })

        // Unmount anything that disappeared or whose host path / mode changed.
        // A changed spec has to be torn down first: fakefs keys the bind table
        // on the guest path, so re-binding without unmounting would leave the
        // old entry in place.
        var nowApplied = have
        for (dir, spec) in have where wantByDir[dir] != spec {
            let err = ISHRuntimeQueue.sync { oases_unmount(dir) }
            if err == 0 {
                nowApplied.removeValue(forKey: dir)
                mountApplyLog.info("unmounted \(dir)")
            } else {
                mountApplyLog.warning("unmount failed dir=\(dir) err=\(err)")
            }
        }

        for spec in want where nowApplied[spec.linuxDir] != spec {
            // Refuse a source the host can't currently read: a dropped
            // security scope would otherwise bind an empty directory and look
            // like the user's files vanished.
            guard FileManager.default.fileExists(atPath: spec.hostPath) else {
                mountApplyLog.warning("skip \(spec.linuxDir) — host path unreachable: \(spec.hostPath)")
                continue
            }
            let err = ISHRuntimeQueue.sync {
                oases_bind_mount(spec.linuxDir, spec.hostPath, spec.readOnly ? 1 : 0)
            }
            if err == 0 {
                nowApplied[spec.linuxDir] = spec
                mountApplyLog.info("mounted \(spec.linuxDir) -> \(spec.hostPath) ro=\(spec.readOnly)")
            } else {
                mountApplyLog.warning("bind_mount failed dir=\(spec.linuxDir) err=\(err)")
            }
        }

        lock.lock()
        applied = nowApplied
        lock.unlock()
    }

    /// Guest paths currently bound, for diagnostics.
    func activeGuestPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return applied.keys.sorted()
    }
}

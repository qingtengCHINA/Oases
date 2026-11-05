//
// ISHRuntimeInit.h
//
// Single-call entry to bring up the iSH Linux runtime. Mirrors the
// minimal subset of `AppDelegate.m -[boot]` needed for
// `ISHShellExecutor` to spawn processes against an Alpine rootfs.
//
// Call exactly once during app launch, after the rootfs has been
// staged on disk. After this returns 0, ISHShellExecutor is live.
//

#ifndef ISHRuntimeInit_h
#define ISHRuntimeInit_h

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Initialize the iSH kernel + filesystem against an Alpine rootfs
/// directory. The path must point at the directory CONTAINING the
/// Alpine tree (i.e. has `bin/`, `etc/`, `lib/`, … as direct
/// children).
///
/// Returns 0 on success, a negative iSH errno otherwise. Safe to
/// call only once per process — subsequent calls are no-ops.
int ish_runtime_initialize(const char *rootfsDataPath);

/// Whether the runtime has been successfully initialised. Read-only
/// after `ish_runtime_initialize` returns; ShellTool consults this
/// to choose between "real shell" and "stub" code paths.
int ish_runtime_is_ready(void);

/// Write a file through the mounted iSH fakefs. Host-side writes into the
/// rootfs data directory are not sufficient because fakefs keeps directory
/// entries and file metadata in meta.db. Call this on the same runtime thread
/// as `ish_runtime_initialize` and shell execution.
///
/// Returns 0 on success or a negative iSH errno on failure. Parent
/// directories are created when needed.
int ish_runtime_write_guest_file(const char *guestPath,
                                 const void *bytes,
                                 size_t length,
                                 int mode);

/// Create a directory tree through the mounted iSH fakefs. This is needed for
/// paths whose host-side directory exists but has not yet been materialized in
/// fakefs metadata.
int ish_runtime_ensure_guest_directory(const char *guestPath);

/// Rewrite the guest's /etc/resolv.conf from the iOS resolver configuration
/// (`res_ninit`: search domains + nameservers, e.g. the Wi-Fi router, carrier
/// or VPN DNS), falling back to public resolvers when none are reported.
/// Mirrors upstream iSH `-[AppDelegate configureDns]`. Safe to call from any
/// thread once the runtime is ready; unchanged content is not rewritten.
///
/// Returns 0 on success or a negative iSH errno.
int oases_refresh_dns(void);

/// Bind-mount a host directory into the guest at `linuxPath`.
///
/// Ported from OpenMinis `ISHKernel.m -[bindMountPath:...]`. The underlying
/// `fakefs_bind_mount` already ships in the prebuilt `libish.a`; this just
/// exposes it on the runtime's own entry-point surface so Swift can reach it
/// through the bridging header like every other iSH call.
///
/// `readOnly` writes the mount root's meta.db entry as mode 0555, which makes
/// iSH's generic N_PARENT_DIR_WRITE check reject writes with EACCES — no extra
/// plumbing needed. Must be called on the dedicated iSH runtime thread.
///
/// Returns 0 on success or a negative iSH errno.
int oases_bind_mount(const char *linuxPath, const char *hostPath, int readOnly);

/// Remove a bind mount previously installed at `linuxPath`.
int oases_unmount(const char *linuxPath);

#ifdef __cplusplus
}
#endif

#endif /* ISHRuntimeInit_h */

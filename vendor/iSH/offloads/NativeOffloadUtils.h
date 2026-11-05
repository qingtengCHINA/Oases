//
//  NativeOffloadUtils.h
//  MinisApp
//
//  Shared utilities for native offload CLI tools.
//  Provides arg parsing, JSON envelope construction, date parsing,
//  and output helpers used by all apple-* commands.
//

#ifndef NativeOffloadUtils_h
#define NativeOffloadUtils_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ── Error codes ──
extern NSString *const NOFF_ERR_AUTHORIZATION_DENIED;
extern NSString *const NOFF_ERR_AUTHORIZATION_NOT_DETERMINED;
extern NSString *const NOFF_ERR_NOT_AVAILABLE;
extern NSString *const NOFF_ERR_INVALID_ARGS;
extern NSString *const NOFF_ERR_NO_DATA;
extern NSString *const NOFF_ERR_INTERNAL_ERROR;

// ── Exit codes ──
enum {
    NOFF_EXIT_SUCCESS     = 0,
    NOFF_EXIT_ERROR       = 1,
    NOFF_EXIT_INVALID_ARGS = 2,
    NOFF_EXIT_AUTH_DENIED = 3,
    NOFF_EXIT_NOT_AVAILABLE = 4,
    /// Refused by the native-offload permission gate (NativeOffloadGate.m);
    /// same code oases-config uses for permission_denied.
    NOFF_EXIT_PERMISSION_DENIED = 126,
};

// ── Argument helpers ──

/// Find the value following a named argument (e.g. --start <value>).
/// Returns nil if not found.
NSString *_Nullable noff_find_arg(int argc, char * _Nonnull * _Nonnull argv, const char * _Nonnull name);

/// Check if a flag is present (e.g. --compact, -q, --help).
BOOL noff_has_flag(int argc, char * _Nonnull * _Nonnull argv, const char * _Nonnull name);

/// Get the subcommand (first non-flag argument after argv[0]).
/// Returns nil if no subcommand found.
NSString *_Nullable noff_get_subcommand(int argc, char * _Nonnull * _Nonnull argv);

/// Collect all positional arguments (non-flag, non-option-value args after subcommand).
NSArray<NSString *> *noff_positional_args(int argc, char * _Nonnull * _Nonnull argv);

// ── Date parsing ──

/// Parse a date string: ISO 8601, relative (-7d, -2h, -30m), or --today.
/// Returns nil on parse failure.
NSDate *_Nullable noff_parse_date(NSString *str);

/// Format a date as ISO 8601 with timezone.
NSString *noff_format_date(NSDate *date);

// ── JSON output ──

/// Build a success envelope: {ok:true, tool, action, data, timestamp}.
NSDictionary *noff_json_envelope(NSString *tool, NSString *action, id data);

/// Build an error envelope: {ok:false, tool, action, error:{code,message}, timestamp}.
NSDictionary *noff_json_error(NSString *tool, NSString *action,
                               NSString *code, NSString *message);

/// Serialize dict to JSON and write to fd.
/// If compact=YES, no whitespace. If quiet=YES, emit only the "data" field.
/// fs_context of the guest task running on this thread (the session whose shell started it),
/// 0 off a guest thread or outside a session. Offload handlers run on the guest thread: read it
/// there, before hopping to another thread.
uint64_t noff_current_fs_context(void);

void noff_emit_json(int fd, NSDictionary *dict, BOOL compact, BOOL quiet);

// ── Help output ──

/// Write a help string to stderr_fd.
void noff_emit_help(int stderr_fd, NSString *helpText);

// ── Main thread dispatch ──

/// Synchronously dispatch a block on the main thread and return the result.
/// Safe to call from any thread. If already on main thread, executes directly.
id _Nullable noff_dispatch_main_sync(id _Nullable (^block)(void));

// ── Guest stub creation ──

/// Create a stub executable in the guest filesystem so the shell can
/// find the command via PATH. Call from *_offload_register() after
/// registering the handler.  `guest_path` is e.g. "/usr/local/bin/apple-clipboard".
/// Safe to call multiple times; existing files are left untouched.
void noff_ensure_guest_stub(const char *guest_path);

// ── Path resolution ──

/// Host directory the kernel mounted as the guest root (the live rootfs
/// `Application Support/iSH-rootfs/data`), or the Swift-side
/// `ISHRootfsManager.dataURL` before the kernel is mounted.
NSString *_Nullable noff_rootfs_data_dir(void);

/// Convert a guest (Linux) path to the host path the calling guest task sees:
/// bind mounts and per-session routing first (e.g. "/var/minis/offloads" →
/// that session's offloads bucket), else the rootfs data dir. `..` is clamped
/// at the guest root. For paths the offload builds itself; for anything that
/// came from the caller use `noff_resolve_guest_path_strict`.
/// Returns nil if the path is empty.
NSString *_Nullable noff_resolve_host_path(NSString *guestPath);

typedef NS_ENUM(NSInteger, NoffPathAccess) {
    /// Rootfs, the session's workspace/attachments/offloads/browser, shared,
    /// skills and memory, plus user-mounted folders.
    NoffPathAccessRead = 0,
    /// Rootfs, the session's workspace/attachments/offloads/browser and shared.
    NoffPathAccessWrite = 1,
    /// Reading a file that is sent to a model (`--attach`): same roots as Write.
    NoffPathAccessAttach = 2,
};

/// Resolve a caller-supplied path argument (already host-translated by the
/// kernel, a raw guest path, or relative to the guest CWD) to a canonical host
/// path that stays inside the roots allowed for `access` — `..`, symlinks and
/// host paths outside the guest-visible tree are rejected. Returns nil and
/// sets `*errorOut` (when non-NULL) to a message for the caller on rejection.
/// Offloads must read/write the returned path, never the raw argument.
NSString *_Nullable noff_resolve_guest_path_strict(NSString *path,
                                                    NoffPathAccess access,
                                                    NSString *_Nullable *_Nullable errorOut);

// ── Read stdin ──

/// Read all available data from stdin_fd (non-blocking, up to 1MB).
/// Returns nil if stdin_fd < 0 or no data.
NSString *_Nullable noff_read_stdin(int stdin_fd);

// ── ObjC exception safety ──

/// Execute a block, catching any ObjC NSException. Returns YES if no exception.
/// Use from Swift to safely call UIKit methods that may throw NSInternalInconsistencyException.
BOOL noff_try_objc(void (NS_NOESCAPE ^_Nonnull block)(void));

NS_ASSUME_NONNULL_END

#endif /* NativeOffloadUtils_h */

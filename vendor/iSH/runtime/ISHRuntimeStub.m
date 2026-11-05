//
// ISHRuntimeStub.m
//
// Symbols that `ISHShellExecutor.m` references from the iSH app's
// `AppDelegate.m`. We're NOT pulling the whole AppDelegate (it owns
// the iSH window, terminal view, settings UI, etc.) — just the
// minimal globals + notification constants the shell executor reads.
//
// Defined exactly as upstream so swapping in the full AppDelegate
// later (if we ever do) is a drop-in replacement.
//

#import <Foundation/Foundation.h>

NSString *const ProcessExitedNotification = @"ProcessExitedNotification";

// --- iOSFS no-op stubs ---
//
// Upstream `app/iOSFS.m` defines `iosfs`/`iosfs_unsafe` fs_ops tables
// and an `iosfs_init()` that re-mounts any saved iOS-Files bookmarks.
// We don't surface iOS-Files mounts in the agent shell, so the
// minimal-correct implementation is empty tables + no-op init. The
// kernel only complains if `fs_register` receives NULL, not if the
// ops table is empty.
//
// `fs_ops` size from upstream is ~24 function pointers + flags;
// allocating a zero-initialised opaque blob big enough is safe — the
// only references are taken from the kernel inside mount_root /
// fs_register, both of which read fields but never call any of the
// op pointers if they're NULL (kernel falls back to default
// behaviour or errors with -ENOSYS, which is fine since no caller
// asks iosfs to do anything).

typedef struct __iosfs_opaque {
    void *slots[64]; // generous bound — never actually dereferenced
} __iosfs_opaque;

const __iosfs_opaque iosfs        = { { 0 } };
const __iosfs_opaque iosfs_unsafe = { { 0 } };

void iosfs_init(void) {
    // No iOS-Files bookmarks to replay in our build — by design.
}

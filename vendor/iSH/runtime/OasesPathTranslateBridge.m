//
//  OasesPathTranslateBridge.m
//

#import "OasesPathTranslateBridge.h"
#define ISH_INTERNAL
#include "fs/fake.h"
#include <string.h>

static OasesPathTranslateBlock g_block = nil;

static bool oases_fakefs_translate(
    const char *guest_path,
    uint64_t fs_context,
    char *out_host_path,
    size_t out_size
) {
    if (g_block == nil || guest_path == NULL || out_host_path == NULL || out_size == 0) {
        return false;
    }
    NSString *guest = [NSString stringWithUTF8String:guest_path];
    if (guest == nil) return false;
    NSString *host = g_block(guest, fs_context);
    if (host.length == 0) return false;
    const char *utf8 = host.UTF8String;
    if (utf8 == NULL) return false;
    size_t n = strlen(utf8);
    if (n >= out_size) n = out_size - 1;
    memcpy(out_host_path, utf8, n);
    out_host_path[n] = '\0';
    return true;
}

void oases_install_path_translate_block(OasesPathTranslateBlock block) {
    g_block = [block copy];
    fakefs_set_path_translate_hook(block ? oases_fakefs_translate : NULL);
}

// MARK: - [Stage 0.3] Reverse hook (host→guest)
//
// Mirrors OpenMinis `ISHKernel.m::installPathReverseHandler` (PathReverse
// category, ~30 lines) without dragging the whole ISHKernel Obj-C singleton
// in. The reverse hook is invoked from realfs_getpath() when fakefs has
// resolved a bind-mounted fd's host APFS path (F_GETPATH) back to a guest
// path; without it, readdir over per-session hook-routed buckets silently
// fails the meta.db inode lookup (see OpenMinis `MinisFsRouter.swift::reverse`
// at lines 119-145).
//
// Reentrancy contract is identical to the forward hook: must be non-blocking
// and reentrant (fakefs calls it from getpath paths under the inode lock).

static OasesPathReverseBlock g_reverse_block = nil;

static bool oases_fakefs_reverse(
    const char *host_path,
    char *out_guest_path,
    size_t out_size
) {
    if (g_reverse_block == nil || host_path == NULL || out_guest_path == NULL || out_size == 0) {
        return false;
    }
    NSString *host = [NSString stringWithUTF8String:host_path];
    if (host == nil) return false;
    NSString *guest = g_reverse_block(host);
    if (guest.length == 0) return false;
    const char *utf8 = guest.UTF8String;
    if (utf8 == NULL) return false;
    size_t n = strlen(utf8);
    if (n >= out_size) n = out_size - 1;
    memcpy(out_guest_path, utf8, n);
    out_guest_path[n] = '\0';
    return true;
}

void oases_install_path_reverse_block(OasesPathReverseBlock block) {
    g_reverse_block = [block copy];
    fakefs_set_path_reverse_hook(block ? oases_fakefs_reverse : NULL);
}

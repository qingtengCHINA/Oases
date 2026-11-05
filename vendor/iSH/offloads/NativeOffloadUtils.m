//
//  NativeOffloadUtils.m
//  MinisApp
//
//  Shared utilities for native offload CLI tools.
//

#import "NativeOffloadUtils.h"
#include "kernel/fs.h"
#include "fs/fd.h"
#include "fs/path.h"
#include <unistd.h>
#include <sys/select.h>
#include <sys/param.h>

#if __has_include("Oases_Chat-Swift.h")
#import "Oases_Chat-Swift.h"
#else
@interface OffloadPathGuard : NSObject
@property (class, nonatomic, readonly, copy) NSString * _Nonnull rootfsDataPath;
+ (NSString * _Nullable)resolvePath:(NSString * _Nonnull)path
                                cwd:(NSString * _Nullable)cwd
                       allowedRoots:(NSArray<NSString *> * _Nonnull)allowedRoots
                 translateGuestPath:(NSString * _Nullable (NS_NOESCAPE ^ _Nonnull)(NSString * _Nonnull))translateGuestPath
                isGuestVisibleMount:(BOOL (^ _Nullable)(NSString * _Nonnull))isGuestVisibleMount
                              error:(NSError * _Nullable * _Nullable)error;
@end
#endif

// Exported by libish (native_offload.c uses the same symbols). Declared here
// because fs/fake.h is ISH_INTERNAL-only.
extern struct mount *g_fakefs_mount;
bool fakefs_bind_mount_translate_path(const char *path, char *out_path, size_t out_size);
bool fakefs_bind_mount_resolve_path(const char *resolved, char *out_path, size_t out_size);

// ── Error code constants ──
NSString *const NOFF_ERR_AUTHORIZATION_DENIED       = @"authorization_denied";
NSString *const NOFF_ERR_AUTHORIZATION_NOT_DETERMINED = @"authorization_not_determined";
NSString *const NOFF_ERR_NOT_AVAILABLE              = @"not_available";
NSString *const NOFF_ERR_INVALID_ARGS               = @"invalid_args";
NSString *const NOFF_ERR_NO_DATA                    = @"no_data";
NSString *const NOFF_ERR_INTERNAL_ERROR             = @"internal_error";

// ── Argument helpers ──

NSString *_Nullable noff_find_arg(int argc, char * _Nonnull * _Nonnull argv, const char * _Nonnull name) {
    for (int i = 1; i < argc - 1; i++) {
        if (strcmp(argv[i], name) == 0) {
            return [NSString stringWithUTF8String:argv[i + 1]];
        }
    }
    return nil;
}

BOOL noff_has_flag(int argc, char * _Nonnull * _Nonnull argv, const char * _Nonnull name) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], name) == 0) return YES;
    }
    return NO;
}

NSString *_Nullable noff_get_subcommand(int argc, char * _Nonnull * _Nonnull argv) {
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] != '-') {
            return [NSString stringWithUTF8String:argv[i]];
        }
        // Skip argument value for known option patterns (--key value)
        if (argv[i][0] == '-' && argv[i][1] == '-' && i + 1 < argc && argv[i + 1][0] != '-') {
            i++; // skip value
        }
    }
    return nil;
}

NSArray<NSString *> *noff_positional_args(int argc, char * _Nonnull * _Nonnull argv) {
    NSMutableArray *args = [NSMutableArray array];
    BOOL foundSubcommand = NO;
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-') {
            // Skip option and its value
            if (argv[i][1] == '-' && i + 1 < argc && argv[i + 1][0] != '-') {
                i++;
            }
            continue;
        }
        if (!foundSubcommand) {
            foundSubcommand = YES;
            continue; // skip the subcommand itself
        }
        [args addObject:[NSString stringWithUTF8String:argv[i]]];
    }
    return args;
}

// ── Date parsing ──

NSDate *_Nullable noff_parse_date(NSString *str) {
    if (!str || str.length == 0) return nil;

    // Relative: -7d, -2h, -30m
    if ([str hasPrefix:@"-"] && str.length >= 2) {
        unichar unit = [str characterAtIndex:str.length - 1];
        NSString *numStr = [str substringWithRange:NSMakeRange(1, str.length - 2)];
        NSInteger num = [numStr integerValue];
        if (num > 0) {
            NSTimeInterval interval = 0;
            switch (unit) {
                case 'd': interval = num * 86400; break;
                case 'h': interval = num * 3600; break;
                case 'm': interval = num * 60; break;
                default: break;
            }
            if (interval > 0) {
                return [NSDate dateWithTimeIntervalSinceNow:-interval];
            }
        }
    }

    // ISO 8601 variants
    NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime
                      | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *d = [iso dateFromString:str];
    if (d) return d;

    // Without fractional seconds
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    d = [iso dateFromString:str];
    if (d) return d;

    // Date-only or datetime without timezone
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.timeZone = [NSTimeZone localTimeZone];
    for (NSString *pattern in @[@"yyyy-MM-dd'T'HH:mm:ss",
                                 @"yyyy-MM-dd'T'HH:mm",
                                 @"yyyy-MM-dd"]) {
        fmt.dateFormat = pattern;
        d = [fmt dateFromString:str];
        if (d) return d;
    }

    return nil;
}

NSString *noff_format_date(NSDate *date) {
    if (!date) return @"";
    NSISO8601DateFormatter *fmt = [[NSISO8601DateFormatter alloc] init];
    fmt.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    fmt.timeZone = [NSTimeZone localTimeZone];
    return [fmt stringFromDate:date];
}

// ── JSON output ──

NSDictionary *noff_json_envelope(NSString *tool, NSString *action, id data) {
    return @{
        @"ok": @YES,
        @"tool": tool,
        @"action": action,
        @"data": data ?: [NSNull null],
        @"timestamp": noff_format_date([NSDate date]),
    };
}

NSDictionary *noff_json_error(NSString *tool, NSString *action,
                               NSString *code, NSString *message) {
    return @{
        @"ok": @NO,
        @"tool": tool,
        @"action": action,
        @"error": @{
            @"code": code,
            @"message": message,
        },
        @"timestamp": noff_format_date([NSDate date]),
    };
}

void noff_emit_json(int fd, NSDictionary *dict, BOOL compact, BOOL quiet) {
    id output = dict;
    if (quiet) {
        // In quiet mode, emit only the "data" field for success, or "error" for failure
        if ([dict[@"ok"] boolValue]) {
            output = dict[@"data"];
        } else {
            output = dict[@"error"];
        }
    }

    if (!output || output == [NSNull null]) {
        dprintf(fd, "{}\n");
        return;
    }

    NSJSONWritingOptions opts = 0;
    if (!compact) {
        opts = NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys;
    }

    NSError *err = nil;
    NSData *json = nil;
    @try {
        json = [NSJSONSerialization dataWithJSONObject:output options:opts error:&err];
    } @catch (NSException *e) {
        NSLog(@"NativeOffloads: JSON serialization exception: %@", e.reason);
    }
    if (!json) {
        dprintf(fd, "{\"error\":\"json_serialization_failed\"}\n");
        return;
    }

    NSString *str = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    dprintf(fd, "%s\n", str.UTF8String);
}

// ── Help output ──

void noff_emit_help(int stderr_fd, NSString *helpText) {
    dprintf(stderr_fd, "%s\n", helpText.UTF8String);
}

// ── Main thread dispatch ──

id _Nullable noff_dispatch_main_sync(id _Nullable (^block)(void)) {
    if ([NSThread isMainThread]) {
        return block();
    }
    __block id result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        result = block();
    });
    return result;
}

// ── Read stdin ──

// ── Guest stub creation ──

void noff_ensure_guest_stub(const char * _Nonnull guest_path) {
    // Ensure parent directories exist (e.g. /usr/local/bin)
    char parent[256];
    strncpy(parent, guest_path, sizeof(parent) - 1);
    parent[sizeof(parent) - 1] = '\0';

    // Walk through the path and mkdir each component
    for (char *p = parent + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            generic_mkdirat(AT_PWD, parent, 0755);
            *p = '/';
        }
    }

    // Create the stub file with execute permission.
    // O_CREAT without O_EXCL: if it already exists, just opens it.
    struct fd *fd = generic_open(guest_path, O_CREAT_ | O_WRONLY_, 0755);
    if (fd && !IS_ERR(fd)) {
        fd_close(fd);
    }
}

// ── Path resolution ──

NSString *_Nullable noff_rootfs_data_dir(void) {
    // The kernel's own mount source is exactly what it translates argv paths
    // into (native_offload.c: build_host_path_for_guest). This used to be
    // hardcoded to Documents/alpine-rootfs/data, a stale tree the kernel never
    // mounts, so offloads read and wrote files the guest could not see.
    struct mount *root = g_fakefs_mount;
    if (root && root->source && root->source[0] == '/') {
        return [NSString stringWithUTF8String:root->source];
    }
    NSString *fallback = OffloadPathGuard.rootfsDataPath;
    return fallback.length > 0 ? fallback : nil;
}

/// Absolute guest path with `.`/`..` collapsed; `..` never climbs above `/`.
static NSString *noff_normalize_guest_path(NSString *guestPath) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *component in [guestPath componentsSeparatedByString:@"/"]) {
        if (component.length == 0 || [component isEqualToString:@"."]) continue;
        if ([component isEqualToString:@".."]) {
            if (parts.count > 0) [parts removeLastObject];
            continue;
        }
        [parts addObject:component];
    }
    return [@"/" stringByAppendingString:[parts componentsJoinedByString:@"/"]];
}

NSString *_Nullable noff_resolve_host_path(NSString *guestPath) {
    if (guestPath.length == 0) return nil;
    NSString *normalized = noff_normalize_guest_path(guestPath);

    // Bind mounts and the per-session path-translate hook (OasesFsRouter) win,
    // exactly as for the kernel's own argv translation. The hook reads the
    // calling task's fs_context, so /var/minis/<bucket> maps to that session.
    char translated[PATH_MAX];
    const char *guest = normalized.UTF8String;
    if (guest && fakefs_bind_mount_translate_path(guest, translated, sizeof(translated))) {
        NSString *host = [NSString stringWithUTF8String:translated];
        if (host.length > 0) return host;
    }

    NSString *dataRoot = noff_rootfs_data_dir();
    if (!dataRoot) return nil;
    NSString *relative = [normalized substringFromIndex:1];
    return relative.length > 0 ? [dataRoot stringByAppendingPathComponent:relative] : dataRoot;
}

/// Host roots the calling guest task may reach for `access`: the rootfs data
/// dir plus its session's buckets as routed right now.
static NSArray<NSString *> *noff_allowed_roots(NoffPathAccess access) {
    static const char *const kWritable[] = {
        "/var/minis/workspace", "/var/minis/attachments", "/var/minis/offloads",
        "/var/minis/browser", "/var/minis/shared",
        "/var/oases/workspace", "/var/oases/attachments", "/var/oases/offloads",
        "/var/oases/browser",
    };
    static const char *const kReadOnly[] = {
        "/var/minis/skills", "/var/minis/memory", "/var/oases/skills", "/var/oases/memory",
    };
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    NSString *dataRoot = noff_rootfs_data_dir();
    if (dataRoot) [roots addObject:dataRoot];
    for (size_t i = 0; i < sizeof(kWritable) / sizeof(kWritable[0]); i++) {
        NSString *host = noff_resolve_host_path(@(kWritable[i]));
        if (host) [roots addObject:host];
    }
    if (access == NoffPathAccessRead) {
        for (size_t i = 0; i < sizeof(kReadOnly) / sizeof(kReadOnly[0]); i++) {
            NSString *host = noff_resolve_host_path(@(kReadOnly[i]));
            if (host) [roots addObject:host];
        }
    }
    return roots;
}

/// True when `hostPath` reverse-maps to a user-mounted folder
/// (/var/{oases,minis}/mounts/<name>/…) through the static bind-mount table.
static BOOL noff_is_mounted_folder_path(NSString *hostPath) {
    const char *host = hostPath.UTF8String;
    char guest[PATH_MAX];
    if (!host || !fakefs_bind_mount_resolve_path(host, guest, sizeof(guest))) return NO;
    NSString *guestPath = [NSString stringWithUTF8String:guest];
    return [guestPath hasPrefix:@"/var/oases/mounts/"] || [guestPath hasPrefix:@"/var/minis/mounts/"];
}

NSString *_Nullable noff_resolve_guest_path_strict(NSString *path,
                                                    NoffPathAccess access,
                                                    NSString *_Nullable *_Nullable errorOut) {
    if (path.length == 0) {
        if (errorOut) *errorOut = @"Empty path.";
        return nil;
    }
    // The kernel chdir()s the handler to the host equivalent of the guest CWD.
    char cwdBuffer[PATH_MAX];
    NSString *cwd = getcwd(cwdBuffer, sizeof(cwdBuffer)) ? [NSString stringWithUTF8String:cwdBuffer] : nil;

    // User-mounted folders are guest-visible but may be mounted read-only, so
    // only reads may reach them.
    BOOL (^mountedFolderCheck)(NSString *) = nil;
    if (access == NoffPathAccessRead) {
        mountedFolderCheck = ^BOOL(NSString *hostPath) { return noff_is_mounted_folder_path(hostPath); };
    }

    NSError *error = nil;
    NSString *resolved =
        [OffloadPathGuard resolvePath:path
                                  cwd:cwd
                         allowedRoots:noff_allowed_roots(access)
                   translateGuestPath:^NSString *(NSString *guestPath) {
                       return noff_resolve_host_path(guestPath);
                   }
                  isGuestVisibleMount:mountedFolderCheck
                                error:&error];
    if (!resolved && errorOut) {
        *errorOut = error.localizedDescription
            ?: [NSString stringWithFormat:@"Path '%@' is outside the Linux sandbox.", path];
    }
    return resolved;
}

// ── Read stdin ──

NSString *_Nullable noff_read_stdin(int stdin_fd) {
    if (stdin_fd < 0) return nil;

    NSMutableData *data = [NSMutableData data];
    char buf[4096];
    ssize_t n;

    // Use select with a short timeout to check if data is available
    fd_set fds;
    struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 }; // 100ms
    FD_ZERO(&fds);
    FD_SET(stdin_fd, &fds);

    while (select(stdin_fd + 1, &fds, NULL, NULL, &tv) > 0) {
        n = read(stdin_fd, buf, sizeof(buf));
        if (n <= 0) break;
        [data appendBytes:buf length:n];
        if (data.length > 1024 * 1024) break; // 1MB cap

        FD_ZERO(&fds);
        FD_SET(stdin_fd, &fds);
        tv.tv_sec = 0;
        tv.tv_usec = 50000; // 50ms for subsequent reads
    }

    if (data.length == 0) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// ── ObjC exception safety ──

BOOL noff_try_objc(void (NS_NOESCAPE ^_Nonnull block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        NSLog(@"noff_try_objc: caught ObjC exception: %@ — %@", e.name, e.reason);
        return NO;
    }
}

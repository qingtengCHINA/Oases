//
// ISHRuntimeInit.m
//
// Minimal iSH runtime boot — extracts just the kernel + filesystem
// steps from upstream `AppDelegate.m -[boot]`. We skip TTY/console
// setup (ISHShellExecutor pipes stdio directly) and the do_execve
// into /sbin/init (we never enter that init loop — we just need PID 1
// to exist so `become_new_init_child()` succeeds).
//
// The sequence MUST match upstream order or kernel asserts hit:
//   1. mount_root(&fakefs, dataPath)       ← rootfs visible
//   2. fs_register(&iosfs / &iosfs_unsafe) ← iOS bridge fs available
//   3. become_first_process()              ← we are PID 1
//   4. FsInitialize()                      ← fs internal setup
//   5. /dev/{null,zero,full,random,urandom,tty,console,ptmx}
//   6. /dev/pts (devptsfs mount)
//   7. /proc (procfs mount)
//   8. iosfs_init()                        ← rebind any saved mounts
//

#import <Foundation/Foundation.h>
#include <string.h>
#include <stdbool.h>
#import "ISHRuntimeInit.h"
#include "kernel/task.h"
#include "kernel/errno.h"
#include "fs/devices.h"
#include "fs/path.h"
#include <resolv.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/un.h>
#include "fs/sock.h"

// Forward declarations from libish public headers. We avoid pulling
// the whole tangled header tree into this TU; only the symbols we
// actually call need to be declared.
struct fs_ops;
extern const struct fs_ops fakefs;
// `fs/fake.h` is guarded by ISH_INTERNAL and drags in the whole header tree;
// these two live in the prebuilt libish.a, so declare them the same way the
// fs_ops symbols above are declared.
int fakefs_bind_mount(const char *linux_path, const char *host_path, bool read_only);
int fakefs_bind_unmount(const char *linux_path);
extern const struct fs_ops procfs;
extern const struct fs_ops devptsfs;
extern const struct fs_ops iosfs;
extern const struct fs_ops iosfs_unsafe;

int mount_root(const struct fs_ops *fs, const char *source);
void fs_register(const struct fs_ops *fs);
int become_first_process(void);
void FsInitialize(void);
int do_mount(const struct fs_ops *fs, const char *source, const char *point, const char *info, int flags);
void iosfs_init(void);

extern NSString *const ProcessExitedNotification;

static void oases_ish_handle_exit(struct task *task, int code) {
    // Match upstream iSH's iOS AppDelegate behavior: the shell executor
    // cares about init and direct children of init. Grandchildren are
    // handled by their parent process inside the guest.
    if (task == NULL) return;
    if (task->parent != NULL && task->parent->parent != NULL)
        return;

    pid_t_ pid = task->pid;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ProcessExitedNotification
                                                            object:nil
                                                          userInfo:@{@"pid": @((int)pid),
                                                                     @"code": @(code)}];
    });
}

static int g_runtime_ready = 0;

int ish_runtime_is_ready(void) {
    return g_runtime_ready;
}

/// [T-ios-ish-af-unix-sandbox] iSH turns every guest AF_UNIX address into a real host path
/// `<sock_tmp_prefix><pid>.<id>`. The built-in prefix is the host's /tmp, which a sandboxed
/// app may not write, so every guest bind() failed with EPERM (tmux, Python multiprocessing,
/// Terraform provider handshakes, any daemon on a unix socket). Point it at the app's own
/// temporary folder. The prefix is a file-name prefix, not a folder; `/private` is dropped so
/// the path fits sun_path (104 bytes, filled by an unchecked sprintf in sock.c). The simulator
/// keeps the default, as upstream iSH does. Must run before any guest process binds.
static void oases_set_up_unix_socket_prefix(void) {
#if TARGET_OS_SIMULATOR
    NSLog(@"iSH: [UnixSock] simulator — keeping default prefix '%s'", sock_tmp_prefix);
#else
    NSString *tempDir = NSTemporaryDirectory();
    if ([tempDir hasPrefix:@"/private/"]) {
        tempDir = [tempDir substringFromIndex:strlen("/private")];
    }
    NSString *prefix = [tempDir stringByAppendingString:@"ishsock"];
    const char *utf8 = prefix.UTF8String;
    if (utf8 == NULL) {
        NSLog(@"iSH: [UnixSock] temp dir unrepresentable — keeping default prefix");
        return;
    }
    const size_t sunPathMax = sizeof(((struct sockaddr_un *)0)->sun_path);
    const size_t suffixWorstCase = 12; // "<pid>.<id>" + NUL
    size_t prefixLen = strlen(utf8);
    if (prefixLen + suffixWorstCase >= sunPathMax) {
        NSLog(@"iSH: [UnixSock] prefix too long for sun_path (%zu + %zu >= %zu) — keeping default",
              prefixLen, suffixWorstCase, sunPathMax);
        return;
    }
    // strdup: the NSString's buffer would dangle once the autorelease pool drains.
    sock_tmp_prefix = strdup(utf8);
    NSLog(@"iSH: [UnixSock] prefix → %s (%zu/%zu bytes)", sock_tmp_prefix, prefixLen, sunPathMax);
#endif
}

int ish_runtime_initialize(const char *rootfsDataPath) {
    if (g_runtime_ready) return 0;
    if (!rootfsDataPath) return -1;

    int err;

    // 1. Mount the Alpine rootfs as / (fakefs over real path)
    err = mount_root(&fakefs, rootfsDataPath);
    if (err < 0) {
        NSLog(@"iSH: mount_root failed: %d (path=%s)", err, rootfsDataPath);
        return err;
    }

    // 2. Register iosfs so iSH knows about iOS-bridge mounts. Even
    //    if we don't use them, FsInitialize / boot expects the
    //    registrations to be in place.
    fs_register(&iosfs);
    fs_register(&iosfs_unsafe);

    // Guest unix sockets bind under the app's temporary folder (before any process runs).
    oases_set_up_unix_socket_prefix();

    // 3. PID 1 — required before any subsequent process spawn.
    err = become_first_process();
    if (err < 0) {
        NSLog(@"iSH: become_first_process failed: %d", err);
        return err;
    }

    // 4. Internal fs setup.
    FsInitialize();

    // 5. /dev nodes. ISHShellExecutor opens /dev/null for stdin, so
    //    that one is mandatory; the others are cheap to create and
    //    keep Alpine userland happy (busybox apk etc. probe for them).
    generic_mknodat(AT_PWD, "/dev/null",    0020666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero",    0020666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full",    0020666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random",  0020666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", 0020666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/tty",     0020666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/console", 0020666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx",    0020666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);

    // 6 + 7. Mount the synthetic fs's. Failure here is non-fatal —
    //        most commands don't actually require /proc.
    do_mount(&procfs,   "proc",   "/proc",   "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);

    // 8. Let iosfs replay any iOS-side saved bookmarks. No-op when
    //    UserDefaults has none, which is our case.
    iosfs_init();

    // ISHShellExecutor waits for ProcessExitedNotification to finish
    // synchronous shell calls. Upstream iSH installs this in
    // AppDelegate; the embedded runtime has to install it explicitly.
    exit_hook = oases_ish_handle_exit;

    g_runtime_ready = 1;
    NSLog(@"iSH runtime initialized successfully (rootfs=%s)", rootfsDataPath);
    return 0;
}

static int ish_runtime_force_fakefs_directory(const char *guestPath) {
    char rootPath[] = "/";
    struct mount *rootMount = mount_find(rootPath);
    if (rootMount == NULL || rootMount->fs != &fakefs) {
        if (rootMount != NULL)
            mount_release(rootMount);
        return _ENODEV;
    }

    inode_t inode = path_get_inode(&rootMount->fakefs, guestPath);
    int result = 0;
    if (inode == 0) {
        struct ish_stat stat = {
            .mode = (uint32_t)(0040000u | 0755u),
            .uid = 0,
            .gid = 0,
            .rdev = 0
        };
        inode_t created = path_create(&rootMount->fakefs, guestPath, &stat);
        result = created == 0 ? _EIO : 0;
    }
    mount_release(rootMount);
    return result;
}

static int ish_runtime_create_guest_directories(const char *guestPath, int includeFinalComponent) {
    if (guestPath == NULL || guestPath[0] != '/')
        return _EINVAL;

    char path[MAX_PATH];
    size_t length = strnlen(guestPath, sizeof(path) - 1);
    if (length == 0 || length >= sizeof(path))
        return _ENAMETOOLONG;
    memcpy(path, guestPath, length);
    path[length] = '\0';

    if (!includeFinalComponent) {
        char *lastSlash = strrchr(path, '/');
        if (lastSlash == NULL || lastSlash == path)
            return 0;
        *lastSlash = '\0';
    }

    char currentPath[MAX_PATH] = {0};
    const char *cursor = path + 1;
    while (*cursor != '\0') {
        const char *slash = strchr(cursor, '/');
        size_t componentLength = slash ? (size_t)(slash - cursor) : strlen(cursor);
        if (componentLength == 0)
            return _EINVAL;

        size_t currentLength = strlen(currentPath);
        if (currentLength + componentLength + 2 >= sizeof(currentPath))
            return _ENAMETOOLONG;
        currentPath[currentLength] = '/';
        memcpy(currentPath + currentLength + 1, cursor, componentLength);
        currentPath[currentLength + componentLength + 1] = '\0';

        int result = generic_mkdirat(AT_PWD, currentPath, 0755);
        if (result < 0 && result != _EEXIST)
            return result;
        // Host-side directories can already exist while their fakefs path
        // records are absent. EEXIST alone does not repair that split-brain
        // state, so force the path entry into meta.db and verify it exists.
        result = ish_runtime_force_fakefs_directory(currentPath);
        if (result < 0)
            return result;
        cursor = slash ? slash + 1 : cursor + componentLength;
    }
    return 0;
}

static int ish_runtime_ensure_guest_parent(const char *guestPath) {
    return ish_runtime_create_guest_directories(guestPath, 0);
}

int oases_bind_mount(const char *linuxPath, const char *hostPath, int readOnly) {
    if (!g_runtime_ready || linuxPath == NULL || hostPath == NULL ||
        linuxPath[0] != '/')
        return _EINVAL;
    // The mount point must exist in fakefs metadata first, or the bind has
    // nothing to attach to.
    int parent = ish_runtime_create_guest_directories(linuxPath, 1);
    if (parent < 0)
        return parent;
    int err = fakefs_bind_mount(linuxPath, hostPath, readOnly != 0);
    NSLog(@"[ISHRuntime] bind_mount linux=%s host=%s ro=%d err=%d",
          linuxPath, hostPath, readOnly, err);
    return err;
}

int oases_unmount(const char *linuxPath) {
    if (!g_runtime_ready || linuxPath == NULL || linuxPath[0] != '/')
        return _EINVAL;
    int err = fakefs_bind_unmount(linuxPath);
    NSLog(@"[ISHRuntime] bind_unmount linux=%s err=%d", linuxPath, err);
    return err;
}

int ish_runtime_ensure_guest_directory(const char *guestPath) {
    if (!g_runtime_ready)
        return _EINVAL;
    int result = ish_runtime_create_guest_directories(guestPath, 1);
    NSLog(@"[ISHRuntime] guest fakefs directory path=%s result=%d current=%p", guestPath, result, current);
    return result;
}

int ish_runtime_write_guest_file(const char *guestPath,
                                 const void *bytes,
                                 size_t length,
                                 int mode) {
    if (!g_runtime_ready || guestPath == NULL || guestPath[0] != '/' ||
        (bytes == NULL && length != 0))
        return _EINVAL;

    int parentResult = ish_runtime_ensure_guest_parent(guestPath);
    if (parentResult < 0)
        return parentResult;

    struct fd *fd = generic_open(guestPath, O_WRONLY_ | O_CREAT_ | O_TRUNC_, mode);
    if (IS_ERR(fd))
        return (int)PTR_ERR(fd);

    size_t offset = 0;
    int result = 0;
    while (offset < length) {
        ssize_t written = fd->ops && fd->ops->write
            ? fd->ops->write(fd, (const char *)bytes + offset, length - offset)
            : _EIO;
        if (written <= 0) {
            result = written < 0 ? (int)written : _EIO;
            break;
        }
        offset += (size_t)written;
    }
    fd_close(fd);
    if (result < 0)
        return result;
    if (offset != length)
        return _EIO;

    int modeResult = generic_setattrat(AT_PWD, guestPath, make_attr(mode, (mode_t_)mode), true);
    if (modeResult < 0)
        return modeResult;

    struct statbuf stat = {0};
    int statResult = generic_statat(AT_PWD, guestPath, &stat, true);
    NSLog(@"[ISHRuntime] guest fakefs write path=%s bytes=%zu stat=%d mode=%o size=%llu current=%p",
          guestPath,
          length,
          statResult,
          stat.mode,
          (unsigned long long)stat.size,
          current);
    return statResult < 0 ? statResult : 0;
}

int oases_refresh_dns(void) {
    if (!g_runtime_ready)
        return _EINVAL;

    NSMutableString *conf = [NSMutableString new];
    int servers = 0;
    struct __res_state res;
    memset(&res, 0, sizeof(res));
    if (res_ninit(&res) == 0) {
        if (res.dnsrch[0] != NULL) {
            [conf appendString:@"search"];
            for (int i = 0; res.dnsrch[i] != NULL; i++)
                [conf appendFormat:@" %s", res.dnsrch[i]];
            [conf appendString:@"\n"];
        }
        union res_sockaddr_union list[MAXNS];
        int found = res_getservers(&res, list, MAXNS);
        char address[NI_MAXHOST];
        for (int i = 0; i < found; i++) {
            if (list[i].sin.sin_len == 0)
                continue;
            if (getnameinfo((struct sockaddr *)&list[i].sin, list[i].sin.sin_len,
                            address, sizeof(address), NULL, 0, NI_NUMERICHOST) != 0)
                continue;
            [conf appendFormat:@"nameserver %s\n", address];
            servers++;
        }
        res_ndestroy(&res);
    }
    if (servers == 0) {
        // No resolver reported (e.g. offline at launch): public resolvers that
        // are reachable from mainland China and elsewhere.
        [conf appendString:@"nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 8.8.8.8\n"];
    }

    static NSString *lastWritten = nil;
    @synchronized ([NSProcessInfo processInfo]) {
        if ([lastWritten isEqualToString:conf])
            return 0;
        struct task *saved = current;
        if (current == NULL) {
            lock(&pids_lock);
            current = pid_get_task(1);
            unlock(&pids_lock);
        }
        const char *bytes = conf.UTF8String;
        int result = ish_runtime_write_guest_file("/etc/resolv.conf", bytes, strlen(bytes), 0644);
        current = saved;
        if (result == 0)
            lastWritten = [conf copy];
        NSLog(@"[ISHRuntime] resolv.conf refreshed servers=%d result=%d", servers, result);
        return result;
    }
}

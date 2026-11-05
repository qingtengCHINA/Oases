//
//  ISHShellExecutor.m
//  iSH
//
//  Shell execution implementation with line-by-line output and process completion
//

#import "ISHShellExecutor.h"
#import "AppDelegate.h"
#import "LinuxInterop.h"

#include <sys/stat.h>
#include <fcntl.h>
#include <poll.h>
#include <stdatomic.h>
#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/errno.h"
#include "kernel/signal.h"
#include "kernel/task.h"
#include "fs/dev.h"
#include "fs/devices.h"
#include "fs/fd.h"
#include "fs/real.h"
#include "fs/tty.h"

#if !defined(GUEST_ARM64)
#error "OasesChat iSH runtime must compile with GUEST_ARM64=1"
#endif

// These checks protect the host bridge from silently reading an x86 task
// layout while linking the ARM64 guest libraries.
_Static_assert(sizeof(struct task) == 0x6a0, "unexpected iSH ARM64 task size");
_Static_assert(offsetof(struct task, pid) == 0x398, "unexpected iSH ARM64 task pid offset");
_Static_assert(offsetof(struct task, files) == 0x450, "unexpected iSH ARM64 task files offset");

#pragma mark - Result Implementation

@interface ISHShellExecutionResult ()
@property (nonatomic, readwrite) int exitCode;
@property (nonatomic, readwrite) int pid;
@property (nonatomic, readwrite) ISHShellExecutorError error;
@property (nonatomic, readwrite, copy) NSString *output;
@property (nonatomic, readwrite, copy) NSString *errorOutput;
@property (nonatomic, readwrite) NSTimeInterval duration;
@end

#pragma mark - Interactive Session

static BOOL ISHShellExecutorTraceIO(void);
static dispatch_queue_t ISHShellInteractiveReaderQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ish.shellexecutor.interactive-reader",
                                      DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}
static BOOL ISHShellExecutorEnsureFdTable(struct task *task);
static BOOL ISHShellExecutorInstallStdio(struct task *task,
                                         struct fd *stdinFd,
                                         struct fd *stdoutFd,
                                         struct fd *stderrFd);
static struct fd *ISHShellExecutorCreateRealFd(int realFd, int flags);
static struct task *ISHShellExecutorInstallInitCurrent(void);
static int ISHShellExecutorReapInitChildren(void);
static void ISHShellExecutorTraceTaskContext(NSString *phase) {
    if (!ISHShellExecutorTraceIO()) return;
    struct task *init = pid_get_task(1);
    NSLog(@"ISHShellExecutor: task context phase=%@ current=%p current_pid=%d init=%p init_pid=%d init_files=%p init_fd_files=%p init_fd_size=%zu",
          phase,
          current,
          current ? current->pid : -1,
          init,
          init ? init->pid : -1,
          init ? init->files : NULL,
          init && init->files ? init->files->files : NULL,
          init && init->files ? (size_t)init->files->size : (size_t)0);
}

typedef NS_ENUM(NSInteger, ISHShellInteractiveTTYChannel) {
    ISHShellInteractiveTTYChannelStdout,
    ISHShellInteractiveTTYChannelStderr
};

@class ISHShellInteractiveSession;

@interface ISHShellInteractiveTTYBridge : NSObject
@property (nonatomic, weak) ISHShellInteractiveSession *owner;
@property (nonatomic) ISHShellInteractiveTTYChannel channel;
@end

@interface ISHShellInteractiveSession ()
@property (nonatomic, readwrite) int pid;
@property (nonatomic) int inputWriteFD;
@property (nonatomic) int stdoutReadFD;
@property (nonatomic) int stderrReadFD;
@property (nonatomic) struct tty *inputTTY;
@property (nonatomic, strong) ISHShellInteractiveTTYBridge *stdoutTTYBridge;
@property (nonatomic, strong) ISHShellInteractiveTTYBridge *stderrTTYBridge;
@property (nonatomic) NSCondition *lineCondition;
@property (nonatomic) NSMutableArray<NSString *> *stdoutLines;
@property (nonatomic) NSMutableArray<NSString *> *stderrLines;
@property (nonatomic) NSMutableData *stdoutPendingData;
@property (nonatomic) NSMutableData *stderrPendingData;
@property (nonatomic) BOOL stdoutClosed;
@property (nonatomic) BOOL stderrClosed;
@property (nonatomic) BOOL inputClosed;
- (instancetype)startExecutableUsingInteractiveTTY:(NSString *)executable
                                           arguments:(NSArray<NSString *> *)arguments
                                          environment:(NSDictionary<NSString *,NSString *> *)environment
                                               error:(NSError **)error;
- (void)startReaderForFD:(int)fd isStdErr:(BOOL)isStdErr;
- (void)readPipeFD:(int)fd isStdErr:(BOOL)isStdErr;
- (void)drainPendingData:(NSMutableData *)pending isStdErr:(BOOL)isStdErr;
- (void)drainPendingData:(NSMutableData *)pending
                isStdErr:(BOOL)isStdErr
            forcePartial:(BOOL)forcePartial;
- (NSString *)readLineFrom:(NSMutableArray<NSString *> *)lines
                     closed:(BOOL)closed
                    timeout:(NSTimeInterval)timeout;
- (void)appendTTYBytes:(const void *)bytes length:(size_t)length isStdErr:(BOOL)isStdErr;
@end

@implementation ISHShellInteractiveTTYBridge
@end

static int ISHShellInteractiveTTYWrite(struct tty *tty,
                                       const void *bytes,
                                       size_t length,
                                       bool blocking) {
    (void)blocking;
    if (tty == NULL || tty->data == NULL)
        return _EIO;

    ISHShellInteractiveTTYBridge *bridge =
        (__bridge ISHShellInteractiveTTYBridge *)tty->data;
    if (ISHShellExecutorTraceIO()) {
        NSLog(@"ISHShellInteractiveTTY: write channel=%ld bytes=%zu tty=%p",
              (long)bridge.channel, length, tty);
    }
    [bridge.owner appendTTYBytes:bytes
                           length:length
                         isStdErr:bridge.channel == ISHShellInteractiveTTYChannelStderr];
    return (int)length;
}

static void ISHShellInteractiveTTYCleanup(struct tty *tty) {
    if (tty == NULL || tty->data == NULL)
        return;
    ISHShellInteractiveTTYBridge *bridge =
        (__bridge_transfer ISHShellInteractiveTTYBridge *)tty->data;
    bridge.owner = nil;
    tty->data = NULL;
}

static const struct tty_driver_ops ISHShellInteractiveTTYDriverOps = {
    .write = ISHShellInteractiveTTYWrite,
    .cleanup = ISHShellInteractiveTTYCleanup
};

static struct tty_driver ISHShellInteractiveTTYDriver = {
    .ops = &ISHShellInteractiveTTYDriverOps,
    .major = TTY_PSEUDO_SLAVE_MAJOR
};

static struct tty *ISHShellExecutorCreateInteractiveTTY(
    ISHShellInteractiveTTYBridge *bridge
) {
    struct tty *tty = pty_open_fake(&ISHShellInteractiveTTYDriver);
    if (tty == NULL || IS_ERR(tty))
        return NULL;

    tty->data = (__bridge_retained void *)bridge;
    lock(&tty->lock);
    // A protocol stream needs canonical input but must not echo requests back
    // into stdout. Disable terminal output translation as well so JSON-RPC
    // lines stay byte-for-byte stable.
    tty->termios.iflags = ICRNL_;
    tty->termios.oflags = 0;
    tty->termios.lflags = ICANON_;
    tty->termios.cc[VMIN_] = 1;
    tty->termios.cc[VTIME_] = 0;
    tty->winsize.row = 24;
    tty->winsize.col = 120;
    unlock(&tty->lock);
    return tty;
}

static struct fd *ISHShellExecutorCreateInteractiveTTYFd(struct tty *tty,
                                                          int flags) {
    if (tty == NULL)
        return NULL;

    struct fd *fd = adhoc_fd_create(&tty_dev.fd);
    if (fd == NULL)
        return NULL;
    fd->flags = flags;
    fd->type = S_IFCHR;
    fd->stat.mode = S_IFCHR | 0620;
    fd->stat.rdev = dev_make(TTY_PSEUDO_SLAVE_MAJOR, tty->num);
    fd->stat.inode = (ino_t)tty->num + 1;
    if (tty_open(tty, fd) < 0) {
        fd_close(fd);
        return NULL;
    }
    return fd;
}

static BOOL ISHShellExecutorInstallInteractiveTTY(struct task *task,
                                                   struct tty *stdoutTTY,
                                                   struct tty *stderrTTY) {
    if (task == NULL || stdoutTTY == NULL || stderrTTY == NULL ||
        task->files == NULL || task->files->files == NULL || task->files->size < 3)
        return NO;

    struct fd *stdinStdoutFD = ISHShellExecutorCreateInteractiveTTYFd(
        stdoutTTY, O_RDWR_ | O_NOCTTY_);
    struct fd *stderrFD = ISHShellExecutorCreateInteractiveTTYFd(
        stderrTTY, O_WRONLY_ | O_NOCTTY_);
    if (stdinStdoutFD == NULL || stderrFD == NULL) {
        if (stdinStdoutFD) fd_close(stdinStdoutFD);
        if (stderrFD) fd_close(stderrFD);
        return NO;
    }

    struct task *saved = current;
    current = task;
    (void)f_close(0);
    (void)f_close(1);
    (void)f_close(2);
    // The initial reference belongs to fd 0; fd 1 takes the retained
    // reference. fd 2 owns the initial stderr reference.
    task->files->files[0] = stdinStdoutFD;
    task->files->files[1] = fd_retain(stdinStdoutFD);
    task->files->files[2] = stderrFD;
    if (ISHShellExecutorTraceIO()) {
        NSLog(@"ISHShellInteractiveSession: installed fd0=%p tty=%p fd1=%p tty=%p fd2=%p tty=%p",
              task->files->files[0], task->files->files[0]->tty,
              task->files->files[1], task->files->files[1]->tty,
              task->files->files[2], task->files->files[2]->tty);
    }
    current = saved;
    return YES;
}

static void ISHShellExecutorCloseInteractiveTTY(struct task *task) {
    if (task == NULL || task->files == NULL || task->files->files == NULL)
        return;
    struct task *saved = current;
    current = task;
    (void)f_close(0);
    (void)f_close(1);
    (void)f_close(2);
    current = saved;
}

@implementation ISHShellInteractiveSession

- (instancetype)initWithInputWriteFD:(int)inputWriteFD
                         stdoutReadFD:(int)stdoutReadFD
                         stderrReadFD:(int)stderrReadFD {
    if ((self = [super init])) {
        _pid = -1;
        _inputWriteFD = inputWriteFD;
        _stdoutReadFD = stdoutReadFD;
        _stderrReadFD = stderrReadFD;
        _lineCondition = [[NSCondition alloc] init];
        _stdoutLines = [NSMutableArray array];
        _stderrLines = [NSMutableArray array];
        _stdoutPendingData = [NSMutableData data];
        _stderrPendingData = [NSMutableData data];
    }
    return self;
}

- (void)dealloc {
    if (_inputWriteFD >= 0) close(_inputWriteFD);
    if (_stdoutReadFD >= 0) close(_stdoutReadFD);
    if (_stderrReadFD >= 0) close(_stderrReadFD);
}

- (void)appendTTYBytes:(const void *)bytes length:(size_t)length isStdErr:(BOOL)isStdErr {
    if (bytes == NULL || length == 0)
        return;
    NSMutableData *pending = isStdErr ? self.stderrPendingData : self.stdoutPendingData;
    @synchronized (pending) {
        [pending appendBytes:bytes length:length];
    }
    [self drainPendingData:pending isStdErr:isStdErr];
}

+ (instancetype)startExecutable:(NSString *)executable
                        arguments:(NSArray<NSString *> *)arguments
                       environment:(NSDictionary<NSString *,NSString *> *)environment
                            error:(NSError **)error {
    if (executable.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"ISHShellInteractiveSession"
                                                 code:-1
                                             userInfo:@{NSLocalizedDescriptionKey: @"Missing executable."}];
        return nil;
    }

    if (ISHShellExecutorTraceIO()) {
        NSLog(@"ISHShellInteractiveSession: start requested executable=%@", executable);
    }

    // Persistent protocol sessions use iSH's in-kernel fake TTY rather than
    // a host pipe. A host pipe can be read by a guest task, but this embedded
    // iSH build cannot reliably wake that guest read when another host thread
    // writes the pipe. The fake TTY wakes through tty_input/tty->produced and
    // keeps the entire round-trip inside the single iSH runtime.
    return [[[self alloc] init] startExecutableUsingInteractiveTTY:executable
                                                          arguments:arguments
                                                         environment:environment
                                                              error:error];
}

- (instancetype)startExecutableUsingInteractiveTTY:(NSString *)executable
                                           arguments:(NSArray<NSString *> *)arguments
                                          environment:(NSDictionary<NSString *,NSString *> *)environment
                                               error:(NSError **)error {
    if (executable.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"ISHShellInteractiveSession"
                                                 code:-1
                                             userInfo:@{NSLocalizedDescriptionKey: @"Missing executable."}];
        return nil;
    }

#if !ISH_LINUX
    ISHShellExecutorTraceTaskContext(@"interactive-before-init");
    struct task *saved_current = ISHShellExecutorInstallInitCurrent();
    if (saved_current == NULL || IS_ERR(saved_current)) {
        current = saved_current;
        if (error) *error = [NSError errorWithDomain:@"ISHShellInteractiveSession"
                                                 code:-3
                                             userInfo:@{NSLocalizedDescriptionKey: @"iSH init task is unavailable."}];
        return nil;
    }

    int err = become_new_init_child();
    if (err < 0) {
        current = saved_current;
        int reaped = ISHShellExecutorReapInitChildren();
        saved_current = ISHShellExecutorInstallInitCurrent();
        if (saved_current != NULL && !IS_ERR(saved_current)) {
            err = become_new_init_child();
        }
        if (err < 0) {
            current = saved_current;
            if (error) *error = [NSError errorWithDomain:@"ISHShellInteractiveSession"
                                                     code:err
                                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"become_new_init_child failed: %d after reaping=%d", err, reaped]}];
            return nil;
        }
    }

    struct task *task = current;
    ISHShellExecutorTraceTaskContext(@"interactive-after-child");
    if (ISHShellExecutorTraceIO()) {
        NSLog(@"ISHShellInteractiveSession: child created task=%p pid=%d saved_current=%p",
              task, task ? task->pid : -1, saved_current);
    }
    if (!ISHShellExecutorEnsureFdTable(task)) {
        current = saved_current;
        if (error) *error = [NSError errorWithDomain:@"ISHShellInteractiveSession"
                                                 code:-4
                                             userInfo:@{NSLocalizedDescriptionKey: @"iSH task fdtable is unavailable."}];
        return nil;
    }

    ISHShellInteractiveSession *session = [[ISHShellInteractiveSession alloc]
        initWithInputWriteFD:-1 stdoutReadFD:-1 stderrReadFD:-1];
    ISHShellInteractiveTTYBridge *stdoutBridge = [ISHShellInteractiveTTYBridge new];
    stdoutBridge.owner = session;
    stdoutBridge.channel = ISHShellInteractiveTTYChannelStdout;
    ISHShellInteractiveTTYBridge *stderrBridge = [ISHShellInteractiveTTYBridge new];
    stderrBridge.owner = session;
    stderrBridge.channel = ISHShellInteractiveTTYChannelStderr;
    session.stdoutTTYBridge = stdoutBridge;
    session.stderrTTYBridge = stderrBridge;

    struct tty *stdoutTTY = ISHShellExecutorCreateInteractiveTTY(stdoutBridge);
    struct tty *stderrTTY = ISHShellExecutorCreateInteractiveTTY(stderrBridge);
    if (ISHShellExecutorTraceIO()) {
        NSLog(@"ISHShellInteractiveSession: fake tty created stdout=%p stderr=%p",
              stdoutTTY, stderrTTY);
    }
    if (stdoutTTY == NULL || stderrTTY == NULL ||
        !ISHShellExecutorInstallInteractiveTTY(task, stdoutTTY, stderrTTY)) {
        if (ISHShellExecutorTraceIO()) {
            NSLog(@"ISHShellInteractiveSession: fake tty install failed task=%p files=%p",
                  task, task ? task->files : NULL);
        }
        ISHShellExecutorCloseInteractiveTTY(task);
        current = saved_current;
        if (error) *error = [NSError errorWithDomain:@"ISHShellInteractiveSession"
                                                 code:-5
                                             userInfo:@{NSLocalizedDescriptionKey: @"Failed to attach interactive fake TTY."}];
        return nil;
    }
    session.inputTTY = stdoutTTY;

    NSMutableArray<NSString *> *fullArgs = [NSMutableArray arrayWithObject:executable];
    if (arguments.count > 0) [fullArgs addObjectsFromArray:arguments];

    size_t argv_cap = 256 * 1024;
    char *argv_buf = malloc(argv_cap);
    if (argv_buf == NULL) {
        ISHShellExecutorCloseInteractiveTTY(task);
        current = saved_current;
        if (error) *error = [NSError errorWithDomain:@"ISHShellInteractiveSession"
                                                 code:-7
                                             userInfo:@{NSLocalizedDescriptionKey: @"Failed to allocate argv buffer."}];
        return nil;
    }
    size_t pos = 0;
    BOOL argvOverflow = NO;
    for (NSString *arg in fullArgs) {
        const char *str = arg.UTF8String;
        size_t len = strlen(str) + 1;
        if (pos + len + 1 >= argv_cap) { argvOverflow = YES; break; }
        memcpy(argv_buf + pos, str, len);
        pos += len;
    }
    if (argvOverflow) {
        free(argv_buf);
        ISHShellExecutorCloseInteractiveTTY(task);
        current = saved_current;
        if (error) *error = [NSError errorWithDomain:@"ISHShellInteractiveSession"
                                                 code:-8
                                             userInfo:@{NSLocalizedDescriptionKey: @"Interactive argv is too long."}];
        return nil;
    }
    argv_buf[pos] = '\0';

    NSMutableData *envpData = [NSMutableData data];
    void (^appendEnv)(NSString *) = ^(NSString *entry) {
        const char *str = entry.UTF8String;
        [envpData appendBytes:str length:strlen(str) + 1];
    };
    appendEnv(@"TERM=xterm-256color");
    appendEnv(@"HOME=/root");
    appendEnv(@"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
#if defined(GUEST_ARM64)
    appendEnv(@"PYTHONMALLOC=malloc");
#endif
    for (NSString *key in environment) {
        appendEnv([NSString stringWithFormat:@"%@=%@", key, environment[key]]);
    }
    uint8_t envpTerminator = 0;
    [envpData appendBytes:&envpTerminator length:1];

    err = do_execve(executable.UTF8String, fullArgs.count, argv_buf, envpData.bytes);
    free(argv_buf);
    if (err < 0) {
        if (ISHShellExecutorTraceIO()) {
            NSLog(@"ISHShellInteractiveSession: do_execve failed err=%d", err);
        }
        ISHShellExecutorCloseInteractiveTTY(task);
        current = saved_current;
        if (error) *error = [NSError errorWithDomain:@"ISHShellInteractiveSession"
                                                 code:err
                                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"do_execve failed: %d", err]}];
        return nil;
    }

    session.pid = task->pid;
    if (ISHShellExecutorTraceIO()) {
        NSLog(@"ISHShellInteractiveSession: started pid=%d fakeTTY=stdout+stdin/%d stderr/%d",
              session.pid, stdoutTTY->num, stderrTTY->num);
    }
    task_start(task);
    current = saved_current;
    return session;
#else
    if (error) *error = [NSError errorWithDomain:@"ISHShellInteractiveSession"
                                             code:-9
                                         userInfo:@{NSLocalizedDescriptionKey: @"Interactive sessions are unavailable on this build."}];
    return nil;
#endif
}

- (BOOL)writeData:(NSData *)data {
    if (data.length == 0) return YES;
    @synchronized (self) {
        if (self.inputClosed) return NO;

        if (self.inputTTY != NULL) {
            if (ISHShellExecutorTraceIO()) {
                NSLog(@"ISHShellInteractiveSession: writing %lu bytes to fake tty pid=%d",
                      (unsigned long)data.length, self.pid);
            }
            ssize_t written = tty_input(self.inputTTY,
                                        (const char *)data.bytes,
                                        data.length,
                                        false);
            size_t buffered = 0;
            bool hasLine = false;
            lock(&self.inputTTY->lock);
            buffered = self.inputTTY->bufsize;
            if (buffered > 0)
                hasLine = self.inputTTY->buf_flag[buffered - 1];
            unlock(&self.inputTTY->lock);
            if (ISHShellExecutorTraceIO()) {
                NSLog(@"ISHShellInteractiveSession: fake tty write completed=%zd pid=%d buffered=%zu hasLine=%d tty=%p",
                      written, self.pid, buffered, hasLine, self.inputTTY);
            }
            return written == (ssize_t)data.length;
        }

        if (self.inputWriteFD < 0) return NO;
        if (ISHShellExecutorTraceIO()) {
            NSLog(@"ISHShellInteractiveSession: writing %lu bytes to stdin fd=%d pid=%d",
                  (unsigned long)data.length, self.inputWriteFD, self.pid);
        }
        const uint8_t *bytes = data.bytes;
        size_t remaining = data.length;
        while (remaining > 0) {
            ssize_t written = write(self.inputWriteFD, bytes, remaining);
            if (written > 0) {
                bytes += written;
                remaining -= (size_t)written;
                continue;
            }
            if (written < 0 && errno == EINTR) continue;
            if (ISHShellExecutorTraceIO()) {
                NSLog(@"ISHShellInteractiveSession: stdin write failed errno=%d pid=%d", errno, self.pid);
            }
            return NO;
        }
        if (ISHShellExecutorTraceIO()) {
            NSLog(@"ISHShellInteractiveSession: stdin write completed pid=%d", self.pid);
        }
        return YES;
    }
}

- (void)closeInput {
    @synchronized (self) {
        if (self.inputWriteFD >= 0) close(self.inputWriteFD);
        self.inputWriteFD = -1;
        self.inputClosed = YES;
    }
}

- (NSString *)readStdoutLineWithTimeout:(NSTimeInterval)timeout {
    return [self readLineFrom:self.stdoutLines closed:self.stdoutClosed timeout:timeout];
}

- (NSString *)readStderrLineWithTimeout:(NSTimeInterval)timeout {
    return [self readLineFrom:self.stderrLines closed:self.stderrClosed timeout:timeout];
}

- (NSString *)readLineFrom:(NSMutableArray<NSString *> *)lines
                     closed:(BOOL)closed
                    timeout:(NSTimeInterval)timeout {
    NSDate *deadline = timeout > 0 ? [NSDate dateWithTimeIntervalSinceNow:timeout] : nil;
    [self.lineCondition lock];
    while (lines.count == 0 && !closed) {
        if (deadline != nil) {
            if (![self.lineCondition waitUntilDate:deadline]) break;
        } else {
            [self.lineCondition wait];
        }
        closed = (lines == self.stdoutLines) ? self.stdoutClosed : self.stderrClosed;
    }
    NSString *line = lines.count > 0 ? lines.firstObject : nil;
    if (line != nil) [lines removeObjectAtIndex:0];
    [self.lineCondition unlock];
    return line;
}

- (void)terminateWithSignal:(int)signal {
    int guestPID = self.pid;
    if (guestPID >= 0) {
        [ISHShellExecutor killProcess:guestPID withSignal:signal];
    }
    [self closeInput];
    [self.lineCondition lock];
    self.stdoutClosed = YES;
    self.stderrClosed = YES;
    [self.lineCondition broadcast];
    [self.lineCondition unlock];
}

- (void)startReaderForFD:(int)fd isStdErr:(BOOL)isStdErr {
    __weak ISHShellInteractiveSession *weakSelf = self;
    dispatch_async(ISHShellInteractiveReaderQueue(), ^{
        [weakSelf readPipeFD:fd isStdErr:isStdErr];
    });
}

- (void)readPipeFD:(int)fd isStdErr:(BOOL)isStdErr {
    NSMutableData *pending = isStdErr ? self.stderrPendingData : self.stdoutPendingData;
    uint8_t buffer[4096];
    while (YES) {
        struct pollfd pollFD = { .fd = fd, .events = POLLIN | POLLHUP | POLLERR };
        int pollResult = poll(&pollFD, 1, 1000);
        if (pollResult < 0 && errno == EINTR) continue;
        if (pollResult < 0) break;
        if (pollResult == 0) continue;
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count > 0) {
            if (ISHShellExecutorTraceIO()) {
                NSLog(@"ISHShellInteractiveSession: read %zd bytes from %@ host fd=%d pid=%d",
                      count, isStdErr ? @"stderr" : @"stdout", fd, self.pid);
            }
            @synchronized (pending) {
                [pending appendBytes:buffer length:(NSUInteger)count];
            }
            [self drainPendingData:pending isStdErr:isStdErr];
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        break;
    }

    [self drainPendingData:pending isStdErr:isStdErr forcePartial:YES];
    close(fd);
    [self.lineCondition lock];
    if (isStdErr) self.stderrClosed = YES;
    else self.stdoutClosed = YES;
    [self.lineCondition broadcast];
    [self.lineCondition unlock];
    if (ISHShellExecutorTraceIO()) {
        NSLog(@"ISHShellInteractiveSession: %@ pipe closed pid=%d",
              isStdErr ? @"stderr" : @"stdout", self.pid);
    }
}

- (void)drainPendingData:(NSMutableData *)pending isStdErr:(BOOL)isStdErr {
    [self drainPendingData:pending isStdErr:isStdErr forcePartial:NO];
}

- (void)drainPendingData:(NSMutableData *)pending
                isStdErr:(BOOL)isStdErr
            forcePartial:(BOOL)forcePartial {
    NSData *newline = [NSData dataWithBytes:"\n" length:1];
    while (YES) {
        NSData *snapshot;
        @synchronized (pending) { snapshot = [pending copy]; }
        NSRange range = [snapshot rangeOfData:newline options:0 range:NSMakeRange(0, snapshot.length)];
        if (range.location == NSNotFound) {
            if (!forcePartial || snapshot.length == 0) return;
            range = NSMakeRange(snapshot.length, 0);
        }
        NSData *lineData = [snapshot subdataWithRange:NSMakeRange(0, range.location)];
        NSUInteger removeLength = range.location + (range.length > 0 ? 1 : 0);
        @synchronized (pending) {
            if (pending.length >= removeLength) [pending replaceBytesInRange:NSMakeRange(0, removeLength) withBytes:NULL length:0];
        }
        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        if (line == nil) line = [[NSString alloc] initWithData:lineData encoding:NSISOLatin1StringEncoding];
        if ([line hasSuffix:@"\r"]) line = [line substringToIndex:line.length - 1];
        if (line == nil) line = @"";
        [self.lineCondition lock];
        NSMutableArray<NSString *> *lines = isStdErr ? self.stderrLines : self.stdoutLines;
        [lines addObject:line];
        [self.lineCondition broadcast];
        [self.lineCondition unlock];
        if (removeLength == snapshot.length) return;
    }
}

@end

@implementation ISHShellExecutionResult
@end

#pragma mark - Execution Context

@interface ISHShellExecutionContext : NSObject {
    int _stdoutPipe[2];
    int _stderrPipe[2];
}
@property (nonatomic) int guestPid;
@property (nonatomic) NSDate *startTime;
@property (nonatomic, copy) ISHShellLineCallback lineCallback;
@property (nonatomic, copy) ISHShellCompletionCallback completion;
@property (nonatomic) NSMutableString *stdoutBuffer;
@property (nonatomic) NSMutableString *stderrBuffer;
@property (nonatomic) dispatch_semaphore_t waitSemaphore;
@property (nonatomic) ISHShellExecutionResult *result;
@property (atomic) BOOL hasExited;
@property (atomic) BOOL stdoutClosed;
@property (atomic) BOOL stderrClosed;
@property (atomic) BOOL completionDelivered;

- (int *)stdoutPipe;
- (int *)stderrPipe;

@end

@implementation ISHShellExecutionContext

- (int *)stdoutPipe {
    return _stdoutPipe;
}

- (int *)stderrPipe {
    return _stderrPipe;
}

- (instancetype)init {
    if (self = [super init]) {
        _stdoutBuffer = [NSMutableString string];
        _stderrBuffer = [NSMutableString string];
        _stdoutPipe[0] = -1;
        _stdoutPipe[1] = -1;
        _stderrPipe[0] = -1;
        _stderrPipe[1] = -1;
        _result = [[ISHShellExecutionResult alloc] init];
        _result.error = ISHShellExecutorErrorNone;
    }
    return self;
}

- (void)cleanup {
    if (_stdoutPipe[0] >= 0) close(_stdoutPipe[0]);
    if (_stdoutPipe[1] >= 0) close(_stdoutPipe[1]);
    if (_stderrPipe[0] >= 0) close(_stderrPipe[0]);
    if (_stderrPipe[1] >= 0) close(_stderrPipe[1]);
    _stdoutPipe[0] = _stdoutPipe[1] = -1;
    _stderrPipe[0] = _stderrPipe[1] = -1;
}

- (void)dealloc {
    [self cleanup];
}

@end

#pragma mark - Executor Implementation

@implementation ISHShellExecutor

static NSMutableDictionary<NSNumber *, ISHShellExecutionContext *> *_activeExecutions;
static dispatch_queue_t _readerQueue;
static dispatch_once_t _onceToken;

/// [T-ish-shell-timeout-leak] Live one-shot reader threads across all
/// executions. Each stranded command pins two of them on the concurrent
/// reader queue, so the leak shows up here as a number that only climbs.
/// Reported by +leakGuardStatus.
static _Atomic int32_t _globalLiveReaders = 0;

static BOOL ISHShellExecutorTraceIO(void) {
    return getenv("OASES_ISH_SELFTEST") != NULL || getenv("OASES_ISH_TRACE_STDIO") != NULL;
}

static ssize_t ISHShellExecutorHostFdRead(struct fd *fd, void *buf, size_t bufsize) {
    ssize_t res;
    if (ISHShellExecutorTraceIO()) {
        NSLog(@"ISHShellExecutor: guest read begin host_fd=%d size=%zu", fd->real_fd, bufsize);
    }
    do {
        res = read(fd->real_fd, buf, bufsize);
    } while (res < 0 && errno == EINTR);
    if (ISHShellExecutorTraceIO()) {
        NSLog(@"ISHShellExecutor: guest read host_fd=%d size=%zu res=%zd errno=%d",
              fd->real_fd, bufsize, res, res < 0 ? errno : 0);
    }
    if (res < 0)
        return errno_map();
    return res;
}

static ssize_t ISHShellExecutorHostFdWrite(struct fd *fd, const void *buf, size_t bufsize) {
    ssize_t res;
    do {
        res = write(fd->real_fd, buf, bufsize);
    } while (res < 0 && errno == EINTR);
    if (ISHShellExecutorTraceIO()) {
        NSLog(@"ISHShellExecutor: guest write host_fd=%d size=%zu res=%zd errno=%d",
              fd->real_fd, bufsize, res, res < 0 ? errno : 0);
    }
    if (res < 0)
        return errno_map();
    return res;
}

static int ISHShellExecutorHostFdClose(struct fd *fd) {
    if (fd->real_fd < 0)
        return 0;
    if (ISHShellExecutorTraceIO()) {
        NSLog(@"ISHShellExecutor: guest close host_fd=%d fd=%p ops=%p", fd->real_fd, fd, fd->ops);
    }
    int err = close(fd->real_fd);
    fd->real_fd = -1;
    if (err < 0)
        return errno_map();
    return 0;
}

static int ISHShellExecutorHostFdGetFlags(struct fd *fd) {
    return fd->flags;
}

static int ISHShellExecutorHostFdSetFlags(struct fd *fd, dword_t arg) {
    fd->flags = (fd->flags & O_ACCMODE_) | (arg & ~O_ACCMODE_);
    return 0;
}

static const struct fd_ops ISHShellExecutorHostFdOps = {
    .read = ISHShellExecutorHostFdRead,
    .write = ISHShellExecutorHostFdWrite,
    .close = ISHShellExecutorHostFdClose,
    .getflags = ISHShellExecutorHostFdGetFlags,
    .setflags = ISHShellExecutorHostFdSetFlags,
};

static BOOL ISHShellExecutorEnsureFdTable(struct task *task) {
    if (task == NULL)
        return NO;

    if (task->files != NULL && !IS_ERR(task->files) &&
        task->files->files != NULL && task->files->size >= 3) {
        return YES;
    }

    if (task->files != NULL && !IS_ERR(task->files)) {
        fdtable_release(task->files);
    }

    task->files = fdtable_new(3);
    if (task->files == NULL || IS_ERR(task->files) ||
        task->files->files == NULL || task->files->size < 3) {
        NSLog(@"ISHShellExecutor: fdtable_new failed for task=%p files=%p",
              task, task ? task->files : NULL);
        task->files = NULL;
        return NO;
    }

    return YES;
}

static BOOL ISHShellExecutorInstallStdio(struct task *task,
                                         struct fd *stdinFd,
                                         struct fd *stdoutFd,
                                         struct fd *stderrFd) {
    if (task == NULL || stdinFd == NULL || stdoutFd == NULL || stderrFd == NULL)
        return NO;

    struct task *saved = current;
    current = task;

    if (task->files == NULL || task->files->files == NULL || task->files->size < 3) {
        NSLog(@"ISHShellExecutor: stdio install missing fd table after close");
        current = saved;
        return NO;
    }

    // Replace the inherited init descriptors before installing the host-backed
    // fds. This is the same ordering used by iSH's DebugServer and is
    // required for both short-lived and interactive children.
    (void)f_close(0);
    (void)f_close(1);
    (void)f_close(2);
    fd_t fd0 = f_install(stdinFd, 0);
    fd_t fd1 = f_install(stdoutFd, 0);
    fd_t fd2 = f_install(stderrFd, 0);
    if (fd0 != 0 || fd1 != 1 || fd2 != 2) {
        NSLog(@"ISHShellExecutor: stdio install returned fd0=%d fd1=%d fd2=%d", fd0, fd1, fd2);
        current = saved;
        return NO;
    }
    current = saved;
    return YES;
}

static struct fd *ISHShellExecutorCreateRealFd(int realFd, int flags) {
    if (realFd < 0)
        return NULL;

    struct fd *fd = adhoc_fd_create(&ISHShellExecutorHostFdOps);
    if (fd == NULL) {
        close(realFd);
        return NULL;
    }

    fd->real_fd = realFd;
    fd->dir = NULL;
    fd->flags = flags;

    struct stat realStat;
    if (fstat(realFd, &realStat) == 0) {
        fd->stat.mode = realStat.st_mode;
        fd->stat.rdev = dev_fake_from_real(realStat.st_rdev);
        fd->stat.inode = realStat.st_ino;
        fd->stat.size = realStat.st_size;
        if (S_ISSOCK(fd->stat.mode) || isatty(realFd)) {
            fd->stat.mode = S_IFCHR | 0620;
            fd->stat.rdev = dev_make(TTY_PSEUDO_SLAVE_MAJOR, 0);
        }
        fd->type = fd->stat.mode & S_IFMT;
    }

    return fd;
}

static struct task *ISHShellExecutorInstallInitCurrent(void) {
    lock(&pids_lock);
    struct task *init = pid_get_task(1);
    unlock(&pids_lock);

    if (init != NULL && !IS_ERR(init)) {
        current = init;
        return init;
    }

    return NULL;
}

static int ISHShellExecutorReapInitChildren(void) {
#if !ISH_LINUX
    struct task *saved = current;
    struct task *init = ISHShellExecutorInstallInitCurrent();
    if (init == NULL || IS_ERR(init)) {
        current = saved;
        return 0;
    }

    int reaped = 0;
    for (int i = 0; i < 1024; i++) {
        int32_t waited = (int32_t)sys_wait4(-1, 0, 1 /* WNOHANG */, 0);
        if (waited <= 0)
            break;
        reaped += 1;
    }
    current = saved;

    if (reaped > 0 && ISHShellExecutorTraceIO()) {
        NSLog(@"ISHShellExecutor: reaped %d init child task(s)", reaped);
    }
    return reaped;
#else
    return 0;
#endif
}

+ (void)initialize {
    if (self == [ISHShellExecutor class]) {
        _activeExecutions = [NSMutableDictionary dictionary];
        dispatch_once(&_onceToken, ^{
            _readerQueue = dispatch_queue_create("com.ish.shellexecutor.reader",
                                                 DISPATCH_QUEUE_CONCURRENT);
        });

        // Register for process exit notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(processDidExit:)
                                                     name:ProcessExitedNotification
                                                   object:nil];
    }
}

#pragma mark - Public API

+ (int)executeCommand:(NSString *)command
         lineCallback:(ISHShellLineCallback)lineCallback
           completion:(ISHShellCompletionCallback)completion {
    return [self executeExecutable:@"/bin/sh"
                         arguments:@[@"-c", command]
                       environment:nil
                      lineCallback:lineCallback
                        completion:completion];
}

+ (int)executeExecutable:(NSString *)executable
               arguments:(NSArray<NSString *> *)arguments
             environment:(NSDictionary<NSString *, NSString *> *)environment
            lineCallback:(ISHShellLineCallback)lineCallback
              completion:(ISHShellCompletionCallback)completion {
    return [self executeExecutable:executable
                         arguments:arguments
                       environment:environment
                         fsContext:0
                      lineCallback:lineCallback
                        completion:completion];
}

+ (int)executeExecutable:(NSString *)executable
               arguments:(NSArray<NSString *> *)arguments
             environment:(NSDictionary<NSString *, NSString *> *)environment
               fsContext:(uint64_t)fsContext
            lineCallback:(ISHShellLineCallback)lineCallback
              completion:(ISHShellCompletionCallback)completion {

    ISHShellExecutionContext *ctx = [[ISHShellExecutionContext alloc] init];
    ctx.lineCallback = lineCallback;
    ctx.completion = completion;
    ctx.startTime = [NSDate date];

    // Create pipes for stdout and stderr
    if (pipe([ctx stdoutPipe]) < 0 || pipe([ctx stderrPipe]) < 0) {
        NSLog(@"ISHShellExecutor: pipe() failed: %s", strerror(errno));
        [ctx cleanup];
        return ISHShellExecutorErrorProcessCreationFailed;
    }

    // Set read ends to non-blocking
    fcntl([ctx stdoutPipe][0], F_SETFL, O_NONBLOCK);
    fcntl([ctx stderrPipe][0], F_SETFL, O_NONBLOCK);

#if !ISH_LINUX
    ISHShellExecutorTraceTaskContext(@"one-shot-before-init");
    struct task *saved_current = ISHShellExecutorInstallInitCurrent();
    if (saved_current == NULL || IS_ERR(saved_current)) {
        [ctx cleanup];
        NSLog(@"ISHShellExecutor: missing init task before child creation current=%p", current);
        return ISHShellExecutorErrorProcessCreationFailed;
    }

    // Create new process. The embedded runtime does not run a real
    // /sbin/init wait loop, so reap exited PID1 children before retrying
    // process creation; otherwise long agent sessions can exhaust the iSH
    // task table with zombies and surface as become_new_init_child < 0.
    int err = become_new_init_child();
    if (err < 0) {
        current = saved_current;
        int reaped = ISHShellExecutorReapInitChildren();
        saved_current = ISHShellExecutorInstallInitCurrent();
        if (saved_current != NULL && !IS_ERR(saved_current)) {
            err = become_new_init_child();
        }
        if (err < 0) {
            current = saved_current;
            [ctx cleanup];
            NSLog(@"ISHShellExecutor: become_new_init_child failed: %d after reaping=%d", err, reaped);
            return ISHShellExecutorErrorProcessCreationFailed;
        }
    }

    struct task *task = current;
    // Per-session path routing (OpenMinis fs_context / MinisFsRouter pattern).
    if (fsContext != 0 && task != NULL && task->group != NULL) {
        task->group->fs_context = fsContext;
    }
    ISHShellExecutorTraceTaskContext(@"one-shot-after-child");
    if (!ISHShellExecutorEnsureFdTable(task)) {
        NSLog(@"ISHShellExecutor: invalid iSH task fdtable after child creation (saved_current=%p current=%p task=%p files=%p)",
              saved_current, current, task, task ? task->files : NULL);
        current = saved_current;
        [ctx cleanup];
        return ISHShellExecutorErrorProcessCreationFailed;
    }

    struct fdtable *taskFiles = task ? task->files : NULL;
    if (task == NULL || taskFiles == NULL || taskFiles->files == NULL || taskFiles->size < 3) {
        NSLog(@"ISHShellExecutor: invalid iSH task context (saved_current=%p current=%p task=%p files=%p)",
              saved_current, current, task, taskFiles);
        current = saved_current;
        [ctx cleanup];
        return ISHShellExecutorErrorProcessCreationFailed;
    }

    // Setup stdin as /dev/null
    struct fd *stdin_fd = ISHShellExecutorCreateRealFd(open("/dev/null", O_RDONLY), O_RDONLY_);
    struct fd *stdout_fd = ISHShellExecutorCreateRealFd(dup([ctx stdoutPipe][1]), O_WRONLY_);
    struct fd *stderr_fd = ISHShellExecutorCreateRealFd(dup([ctx stderrPipe][1]), O_WRONLY_);

    if (stdin_fd == NULL || stdout_fd == NULL || stderr_fd == NULL) {
        if (stdin_fd) fd_close(stdin_fd);
        if (stdout_fd) fd_close(stdout_fd);
        if (stderr_fd) fd_close(stderr_fd);
        current = saved_current;
        [ctx cleanup];
        NSLog(@"ISHShellExecutor: failed to attach stdio fds: %s", strerror(errno));
        return ISHShellExecutorErrorProcessCreationFailed;
    }

    if (!ISHShellExecutorInstallStdio(task, stdin_fd, stdout_fd, stderr_fd)) {
        current = saved_current;
        [ctx cleanup];
        return ISHShellExecutorErrorProcessCreationFailed;
    }

    if (ISHShellExecutorTraceIO()) {
        NSLog(@"ISHShellExecutor: stdio attached task=%p files=%p stdin=%d stdout=%d stderr=%d stdoutPipe=[%d,%d] stderrPipe=[%d,%d]",
              task,
              taskFiles,
              task->files->files[0] ? task->files->files[0]->real_fd : -1,
              task->files->files[1] ? task->files->files[1]->real_fd : -1,
              task->files->files[2] ? task->files->files[2]->real_fd : -1,
              [ctx stdoutPipe][0],
              [ctx stdoutPipe][1],
              [ctx stderrPipe][0],
              [ctx stderrPipe][1]);
    }

    // Close write ends in parent
    close([ctx stdoutPipe][1]);
    close([ctx stderrPipe][1]);
    [ctx stdoutPipe][1] = -1;
    [ctx stderrPipe][1] = -1;

    // Build argv (NUL-separated string)
    NSMutableArray<NSString *> *fullArgs = [NSMutableArray arrayWithObject:executable];
    if (arguments) {
        [fullArgs addObjectsFromArray:arguments];
    }

    // 256 KB argv buffer — large enough for shell heredocs that
    // inline real-world file contents (HTML/JSON snippets etc.).
    // The original 4 KB rejected `sh -c "cat > foo.html << EOF…EOF"`
    // for anything bigger than ~3 KB of body, which is the failure
    // mode the user observed as "argv too long" + "do_execve -8".
    // Allocate on the heap to stay friendly to small stacks.
    size_t argv_cap = 256 * 1024;
    char *argv_buf = malloc(argv_cap);
    if (argv_buf == NULL) {
        current = saved_current;
        [ctx cleanup];
        NSLog(@"ISHShellExecutor: argv buffer malloc failed");
        return ISHShellExecutorErrorExecFailed;
    }
    size_t pos = 0;
    BOOL argvOverflow = NO;
    for (NSString *arg in fullArgs) {
        const char *str = arg.UTF8String;
        size_t len = strlen(str) + 1;
        if (pos + len + 1 >= argv_cap) {  // +1 for final NUL
            argvOverflow = YES;
            break;
        }
        memcpy(argv_buf + pos, str, len);
        pos += len;
    }
    if (argvOverflow) {
        free(argv_buf);
        current = saved_current;
        [ctx cleanup];
        NSLog(@"ISHShellExecutor: argv too long (cap=%zu)", argv_cap);
        return ISHShellExecutorErrorExecFailed;
    }
    // Add final NUL terminator for double-NUL ending
    argv_buf[pos] = '\0';

    // Build envp as a true NUL-separated C string vector. NSString
    // literals do not preserve embedded NUL bytes in the way execve
    // expects, so use NSMutableData and append each string plus its
    // terminator explicitly.
    NSMutableData *envpData = [NSMutableData data];
    void (^appendEnv)(NSString *) = ^(NSString *entry) {
        const char *str = entry.UTF8String;
        [envpData appendBytes:str length:strlen(str) + 1];
    };

    // Default environment
    appendEnv(@"TERM=xterm-256color");
    appendEnv(@"HOME=/root");
    appendEnv(@"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
#if defined(GUEST_ARM64)
    appendEnv(@"PYTHONMALLOC=malloc");
#endif

    // Custom environment
    if (environment) {
        for (NSString *key in environment) {
            appendEnv([NSString stringWithFormat:@"%@=%@", key, environment[key]]);
        }
    }

    // Add final NUL terminator for double-NUL ending
    uint8_t envpTerminator = 0;
    [envpData appendBytes:&envpTerminator length:1];

    const char *envp = envpData.bytes;

    // Execute
    err = do_execve(executable.UTF8String, fullArgs.count, argv_buf, envp);
    free(argv_buf);
    if (err < 0) {
        current = saved_current;
        [ctx cleanup];
        NSLog(@"ISHShellExecutor: do_execve failed: %d", err);
        return ISHShellExecutorErrorExecFailed;
    }
    // Get guest PID before start. Register the execution and start
    // pipe readers before `task_start`: very short commands can exit
    // immediately, and the exit hook would otherwise post a notification
    // before `_activeExecutions` knows about this pid.
    ctx.guestPid = task->pid;
    ctx.result.pid = ctx.guestPid;

    @synchronized(_activeExecutions) {
        _activeExecutions[@(ctx.guestPid)] = ctx;
    }

    [self startReaderForPipe:[ctx stdoutPipe][0] context:ctx isStdErr:NO];
    [self startReaderForPipe:[ctx stderrPipe][0] context:ctx isStdErr:YES];

    task_start(task);
    current = saved_current;

    return ctx.guestPid;
#else
    // TODO: Linux implementation using linux_start_session
    [ctx cleanup];
    return ISHShellExecutorErrorProcessCreationFailed;
#endif
}

+ (ISHShellExecutionResult *)executeCommandSync:(NSString *)command
                                        timeout:(NSTimeInterval)timeout
                                   lineCallback:(ISHShellLineCallback)lineCallback {

    ISHShellExecutionContext *ctx = [[ISHShellExecutionContext alloc] init];
    ctx.lineCallback = lineCallback;
    ctx.waitSemaphore = dispatch_semaphore_create(0);
    ctx.startTime = [NSDate date];

    __block ISHShellExecutionResult *result = nil;

    int pid = [self executeCommand:command
                      lineCallback:lineCallback
                        completion:^(ISHShellExecutionResult *execResult) {
        result = execResult;
        dispatch_semaphore_signal(ctx.waitSemaphore);
    }];

    if (pid < 0) {
        // Execution failed
        result = [[ISHShellExecutionResult alloc] init];
        result.error = (ISHShellExecutorError)pid;
        result.exitCode = -1;
        return result;
    }

    // Wait for completion or timeout
    dispatch_time_t waitTime = timeout > 0
        ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))
        : DISPATCH_TIME_FOREVER;

    long waitResult = dispatch_semaphore_wait(ctx.waitSemaphore, waitTime);

    if (waitResult != 0) {
        // Timeout - kill the whole command, not just the root: children
        // that inherited the stdout/stderr pipes would otherwise keep
        // running and hold the pipes open, so the readers never see EOF.
        [self killProcessGroup:pid];
        // [T-ish-shell-timeout-leak] Then release the context HERE instead of
        // leaving it to the exit notification the kill is expected to
        // provoke (see +finalizeTimedOutPid:). Kill first, finalise second:
        // the signals go out while the pipes are still read, so what the
        // command printed before the deadline lands in the result.
        //
        // Returned through a local, never written to `result`: finalising
        // delivers the completion block on the main queue right now, and
        // that block assigns `result` - two threads storing to one __block
        // strong variable is an ARC over-release.
        ISHShellExecutionResult *timedOut = [self finalizeTimedOutPidReturningResult:pid];
        ISHShellExecutorReapInitChildren();
        return timedOut;
    }

    ISHShellExecutorReapInitChildren();
    return result;
}

+ (ISHShellExecutionResult *)waitForCommandStartedBy:(int (NS_NOESCAPE ^)(ISHShellCompletionCallback completion))start
                                             timeout:(NSTimeInterval)timeout {
    NSAssert(![NSThread isMainThread], @"waitForCommandStartedBy: would deadlock on the main thread");
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block ISHShellExecutionResult *result = nil;
    int pid = start(^(ISHShellExecutionResult *execResult) {
        result = execResult;
        dispatch_semaphore_signal(done);
    });
    if (pid < 0) {
        ISHShellExecutionResult *failed = [[ISHShellExecutionResult alloc] init];
        failed.error = (ISHShellExecutorError)pid;
        failed.exitCode = -1;
        return failed;
    }
    dispatch_time_t waitTime = timeout > 0
        ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))
        : DISPATCH_TIME_FOREVER;
    if (dispatch_semaphore_wait(done, waitTime) != 0) {
        [self killProcessGroup:pid];
        // [T-ish-shell-timeout-leak] Same self-heal as executeCommandSync.
        return [self finalizeTimedOutPidReturningResult:pid];
    }
    return result;
}

#pragma mark - Timeout Teardown

+ (void)finalizeTimedOutPid:(int)pid {
    (void)[self finalizeContextForTimedOutPid:pid];
}

/// Finalises `pid` and returns the result a synchronous caller should report:
/// the context's own (with the output captured before the deadline), or a
/// synthesised empty timeout result when the context had already gone.
+ (ISHShellExecutionResult *)finalizeTimedOutPidReturningResult:(int)pid {
    ISHShellExecutionContext *ctx = [self finalizeContextForTimedOutPid:pid];
    if (ctx.result && ctx.completionDelivered) {
        return ctx.result;
    }
    ISHShellExecutionResult *timedOut = [[ISHShellExecutionResult alloc] init];
    timedOut.error = ISHShellExecutorErrorTimeout;
    timedOut.pid = pid;
    timedOut.exitCode = -1;
    timedOut.output = @"";
    timedOut.errorOutput = @"";
    return timedOut;
}

/// [T-ish-shell-timeout-leak] The timeout used to kill and return, leaving
/// every teardown step to ProcessExitedNotification. When that notification
/// does not come - the task is stuck in a host call, or the exit hook skips
/// it - nothing ran: the context stayed in _activeExecutions, `hasExited` and
/// `completionDelivered` stayed NO, and both readers polled their pipe every
/// 10 ms for as long as any surviving task held its write end. Waiting on the
/// notification made cleanup depend on the cooperation of a process we had
/// just decided to kill; now the timeout owns its own teardown.
///
/// This is the same forced completion processDidExit: falls back to 500 ms
/// after an exit: mark both pipes done so tryCompleteExecution: delivers the
/// buffered output, which sets `completionDelivered`, which ends both reader
/// loops (they close their own fds on the way out). Returns the context it
/// finalised, or nil if `pid` was not registered.
+ (ISHShellExecutionContext *)finalizeContextForTimedOutPid:(int)pid {
    ISHShellExecutionContext *ctx;
    @synchronized(_activeExecutions) {
        ctx = _activeExecutions[@(pid)];
    }
    if (ctx == nil) {
        // Already completed (it exited just before the deadline) or a second
        // call: nothing to do.
        return nil;
    }
    @synchronized(ctx) {
        if (ctx.completionDelivered) return ctx;
        if (!ctx.hasExited) {
            ctx.hasExited = YES;
            ctx.result.exitCode = -1;
            ctx.result.error = ISHShellExecutorErrorTimeout;
            ctx.result.duration = -[ctx.startTime timeIntervalSinceNow];
        }
        ctx.stdoutClosed = YES;
        ctx.stderrClosed = YES;
    }
    NSLog(@"ISHShellExecutor[timeout]: finalising pid=%d after kill (%@)",
          pid, [self leakGuardStatus]);
    [self tryCompleteExecution:ctx];
    return ctx;
}

+ (NSString *)leakGuardStatus {
    NSUInteger active;
    @synchronized(_activeExecutions) { active = _activeExecutions.count; }
    return [NSString stringWithFormat:@"activeExecutions=%lu liveReaders=%d",
            (unsigned long)active, atomic_load(&_globalLiveReaders)];
}

+ (int)reapInitChildren {
    return ISHShellExecutorReapInitChildren();
}

+ (BOOL)killProcess:(int)pid withSignal:(int)signal {
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    struct task *task = pid_get_task((dword_t)pid);
    if (task) {
        send_signal(task, signal, info);
    }
    unlock(&pids_lock);
    return task != NULL;
}

// [Stage 0.3] Mirrors OpenMinis `ISHShellExecutor.m::+killProcessGroup:`
// (lines 545-628). Re-verify the task pointer on the deferred SIGKILL pass —
// if the root has already exited and its pid was recycled to an unrelated
// task, the pointer comparison fails and we abort the sweep. Otherwise we
// would kill an innocent command and its descendants. SIGTERM may be caught
// or, for tasks blocked inside host nanosleep, need the pthread_kill wakeup
// that send_signal already issues — give the wakeup a chance to land and the
// signal handler to run before escalating.

static BOOL OasesTaskIsDescendantOf(struct task *t, pid_t_ rootPid) {
    int hops = 0;
    while (t != NULL && hops < MAX_PID) {
        if (t->pid == rootPid) return YES;
        t = t->parent;
        hops++;
    }
    return NO;
}

+ (void)killProcessGroup:(int)pid {
    if (pid <= 1) {
        NSLog(@"ISHShellExecutor: refusing killProcessGroup for pid=%d", pid);
        return;
    }
    struct siginfo_ info = SIGINFO_NIL;

    lock(&pids_lock);
    struct task *rootTask = pid_get_task((dword_t)pid);
    pid_t_ pgid = 0;
    if (rootTask) {
        pgid = rootTask->group->pgid;
        for (int i = 2; i < MAX_PID; i++) {
            struct task *t = pid_get_task(i);
            if (!t) continue;
            BOOL byPgid = (pgid != 0 && t->group->pgid == pgid);
            BOOL byAncestry = OasesTaskIsDescendantOf(t, (pid_t_)pid);
            if (byPgid || byAncestry) {
                send_signal(t, SIGTERM_, info);
            }
        }
    }
    unlock(&pids_lock);

    if (rootTask == NULL) {
        return;
    }

    int capturedPid = pid;
    struct task *capturedRoot = rootTask;
    pid_t_ capturedPgid = pgid;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)), dispatch_get_global_queue(0, 0), ^{
        lock(&pids_lock);
        struct task *still = pid_get_task((dword_t)capturedPid);
        if (still != capturedRoot) {
            unlock(&pids_lock);
            return;
        }
        for (int i = 2; i < MAX_PID; i++) {
            struct task *t = pid_get_task(i);
            if (!t) continue;
            BOOL byPgid = (capturedPgid != 0 && t->group->pgid == capturedPgid);
            BOOL byAncestry = OasesTaskIsDescendantOf(t, (pid_t_)capturedPid);
            if (byPgid || byAncestry) {
                send_signal(t, SIGKILL_, info);
            }
        }
        unlock(&pids_lock);
    });
}

#pragma mark - Process Exit Handling

+ (void)processDidExit:(NSNotification *)notification {
    int pid = [notification.userInfo[@"pid"] intValue];
    int exitCode = [notification.userInfo[@"code"] intValue];

    ISHShellExecutionContext *ctx;
    @synchronized(_activeExecutions) {
        ctx = _activeExecutions[@(pid)];
        if (!ctx) return;
    }

    @synchronized(ctx) {
        if (ctx.hasExited) return;
        ctx.hasExited = YES;
        ctx.result.exitCode = exitCode;
        ctx.result.duration = -[ctx.startTime timeIntervalSinceNow];
    }

    if (ISHShellExecutorTraceIO()) {
        NSLog(@"ISHShellExecutor: guest pid=%d exited code=%d stdoutClosed=%d stderrClosed=%d",
              pid, exitCode, ctx.stdoutClosed, ctx.stderrClosed);
    }

    [self tryCompleteExecution:ctx];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), _readerQueue, ^{
        @synchronized(ctx) {
            if (!ctx.hasExited || ctx.completionDelivered)
                return;
            if (ISHShellExecutorTraceIO()) {
                NSLog(@"ISHShellExecutor: forcing pipe completion pid=%d stdoutClosed=%d stderrClosed=%d",
                      ctx.guestPid, ctx.stdoutClosed, ctx.stderrClosed);
            }
            ctx.stdoutClosed = YES;
            ctx.stderrClosed = YES;
        }
        [self tryCompleteExecution:ctx];
    });
}

+ (void)tryCompleteExecution:(ISHShellExecutionContext *)ctx {
    if (ctx == nil)
        return;

    BOOL shouldComplete = NO;
    @synchronized(ctx) {
        shouldComplete = ctx.hasExited && ctx.stdoutClosed && ctx.stderrClosed && !ctx.completionDelivered;
        if (shouldComplete) {
            ctx.completionDelivered = YES;
            @synchronized(ctx.stdoutBuffer) {
                ctx.result.output = [ctx.stdoutBuffer copy];
            }
            @synchronized(ctx.stderrBuffer) {
                ctx.result.errorOutput = [ctx.stderrBuffer copy];
            }
        }
    }

    if (!shouldComplete)
        return;

    @synchronized(_activeExecutions) {
        if (ctx.guestPid > 0) {
            [_activeExecutions removeObjectForKey:@(ctx.guestPid)];
        }
    }

    if (ISHShellExecutorTraceIO()) {
        NSLog(@"ISHShellExecutor: completing pid=%d exit=%d stdout=%lu stderr=%lu",
              ctx.guestPid,
              ctx.result.exitCode,
              (unsigned long)ctx.result.output.length,
              (unsigned long)ctx.result.errorOutput.length);
    }

    [ctx cleanup];

    if (ctx.completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ctx.completion(ctx.result);
        });
    }
}

#pragma mark - Pipe Reading

+ (void)startReaderForPipe:(int)fd context:(ISHShellExecutionContext *)ctx isStdErr:(BOOL)isStdErr {
    // The reader owns `fd` from here on and closes it when it stops, so
    // -cleanup never closes a descriptor a reader is still polling (its
    // number could already belong to another command's pipe).
    if (isStdErr) {
        [ctx stderrPipe][0] = -1;
    } else {
        [ctx stdoutPipe][0] = -1;
    }
    // [T-ish-shell-timeout-leak] Counted before the dispatch so a reader that
    // is queued but not yet running (the pool is what this leak exhausts)
    // still shows up in +leakGuardStatus.
    atomic_fetch_add(&_globalLiveReaders, 1);
    dispatch_async(_readerQueue, ^{
        [self readPipe:fd context:ctx isStdErr:isStdErr];
        atomic_fetch_sub(&_globalLiveReaders, 1);
    });
}

// How many bytes at the end of `bytes` start a UTF-8 sequence that continues in the next
// read (0–3). A read boundary can fall inside a multi-byte character; decoding the chunk on
// its own would then fail and the whole chunk fell back to Latin-1 (garbled CJK output).
static NSUInteger ISHIncompleteUTF8Tail(const uint8_t *bytes, NSUInteger length) {
    for (NSUInteger back = 1; back <= 3 && back <= length; back++) {
        uint8_t b = bytes[length - back];
        if ((b & 0xC0) == 0x80) continue;          // continuation byte: keep looking
        NSUInteger need = (b & 0x80) == 0 ? 1
            : (b & 0xE0) == 0xC0 ? 2
            : (b & 0xF0) == 0xE0 ? 3
            : (b & 0xF8) == 0xF0 ? 4 : 1;
        return need > back ? back : 0;
    }
    return 0;
}

static NSString *ISHDecodeChunk(const uint8_t *bytes, NSUInteger length) {
    NSString *text = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    // Not UTF-8 (binary output): Latin-1 keeps every byte.
    return text ?: [[NSString alloc] initWithBytes:bytes length:length encoding:NSISOLatin1StringEncoding];
}

// A command's captured output keeps its first and last kISHOutputKeep characters; the middle
// of a longer one is dropped (`yes`, `cat` of a large file) so it cannot exhaust memory.
static const NSUInteger kISHOutputKeep = 512 * 1024;
static NSString *const kISHOutputOmittedMarker = @"\n[… Oases: the middle of this very long output was dropped …]\n";

static void ISHAppendCapped(NSMutableString *buffer, NSString *text) {
    [buffer appendString:text];
    NSUInteger limit = kISHOutputKeep * 2 + kISHOutputOmittedMarker.length;
    // Trim in batches (64K over the limit) so a steady stream does not trim on every line.
    if (buffer.length <= limit + 64 * 1024) return;
    NSRange marker = [buffer rangeOfString:kISHOutputOmittedMarker options:0
                                     range:NSMakeRange(0, MIN(buffer.length, kISHOutputKeep + kISHOutputOmittedMarker.length))];
    NSUInteger dropFrom;
    if (marker.location == NSNotFound) {
        [buffer insertString:kISHOutputOmittedMarker atIndex:kISHOutputKeep];
        dropFrom = kISHOutputKeep + kISHOutputOmittedMarker.length;
    } else {
        dropFrom = NSMaxRange(marker);
    }
    if (buffer.length > dropFrom + kISHOutputKeep) {
        NSRange drop = NSMakeRange(dropFrom, buffer.length - dropFrom - kISHOutputKeep);
        drop = [buffer rangeOfComposedCharacterSequencesForRange:drop];
        [buffer deleteCharactersInRange:drop];
    }
}

+ (void)readPipe:(int)fd context:(ISHShellExecutionContext *)ctx isStdErr:(BOOL)isStdErr {
    char buffer[4096];
    NSMutableString *lineBuffer = [NSMutableString string];
    NSMutableString *outputBuffer = isStdErr ? ctx.stderrBuffer : ctx.stdoutBuffer;
    // Bytes of a UTF-8 character cut off by the end of the previous read.
    NSMutableData *pending = [NSMutableData data];

    // Stop once the result was delivered without our EOF (the forced
    // completion after the root exited while a background child still
    // holds the pipe) instead of polling forever.
    while (!ctx.completionDelivered) {
        ssize_t bytesRead = read(fd, buffer, sizeof(buffer) - 1);

        if (bytesRead > 0) {
            if (ISHShellExecutorTraceIO()) {
                NSLog(@"ISHShellExecutor: read %zd bytes from %@ pipe fd=%d",
                      bytesRead, isStdErr ? @"stderr" : @"stdout", fd);
            }
            [pending appendBytes:buffer length:(NSUInteger)bytesRead];
            const uint8_t *bytes = pending.bytes;
            NSUInteger complete = pending.length - ISHIncompleteUTF8Tail(bytes, pending.length);
            if (complete == 0) continue;
            NSString *chunk = ISHDecodeChunk(bytes, complete);
            [pending replaceBytesInRange:NSMakeRange(0, complete) withBytes:NULL length:0];

            [lineBuffer appendString:chunk];

            // Process complete lines
            [self processLines:lineBuffer
                       context:ctx
                  outputBuffer:outputBuffer
                      isStdErr:isStdErr];

        } else if (bytesRead == 0) {
            // EOF - pipe closed
            break;
        } else {
            // Error or would block
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                usleep(10000); // 10ms
                continue;
            } else {
                break;
            }
        }
    }

    // A character the stream ended in the middle of.
    if (pending.length > 0) {
        [lineBuffer appendString:ISHDecodeChunk(pending.bytes, pending.length)];
    }

    // Process any remaining partial line
    if (lineBuffer.length > 0) {
        @synchronized(outputBuffer) {
            ISHAppendCapped(outputBuffer, lineBuffer);
        }

        if (ctx.lineCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ctx.lineCallback([lineBuffer copy], isStdErr);
            });
        }
    }

    close(fd);
    if (isStdErr) {
        ctx.stderrClosed = YES;
    } else {
        ctx.stdoutClosed = YES;
    }
    if (ISHShellExecutorTraceIO()) {
        NSLog(@"ISHShellExecutor: %@ pipe fd=%d closed", isStdErr ? @"stderr" : @"stdout", fd);
    }
    [self tryCompleteExecution:ctx];
}

+ (void)processLines:(NSMutableString *)lineBuffer
             context:(ISHShellExecutionContext *)ctx
        outputBuffer:(NSMutableString *)outputBuffer
            isStdErr:(BOOL)isStdErr {

    while (YES) {
        NSRange newlineRange = [lineBuffer rangeOfString:@"\n"];
        if (newlineRange.location == NSNotFound) {
            break;
        }

        // Extract line without newline
        NSString *line = [lineBuffer substringToIndex:newlineRange.location];

        // Remove processed line from buffer
        [lineBuffer deleteCharactersInRange:NSMakeRange(0, newlineRange.location + 1)];

        // Add to output buffer
        @synchronized(outputBuffer) {
            ISHAppendCapped(outputBuffer, [line stringByAppendingString:@"\n"]);
        }

        // Call line callback
        if (ctx.lineCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ctx.lineCallback(line, isStdErr);
            });
        }
    }
}

@end

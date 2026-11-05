//
//  ISHShellExecutor.h
//  iSH
//
//  Shell execution interface with line-by-line output and process completion
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ISHShellExecutorError) {
    ISHShellExecutorErrorNone = 0,
    ISHShellExecutorErrorProcessCreationFailed = -1,
    ISHShellExecutorErrorExecFailed = -2,
    ISHShellExecutorErrorTimeout = -3,
    ISHShellExecutorErrorCancelled = -4,
};

@interface ISHShellExecutionResult : NSObject

/// Exit code of the shell process (0 = success)
@property (nonatomic, readonly) int exitCode;

/// Guest process PID
@property (nonatomic, readonly) int pid;

/// Error code if execution failed
@property (nonatomic, readonly) ISHShellExecutorError error;

/// Complete stdout output (all lines joined)
@property (nonatomic, readonly, copy) NSString *output;

/// Complete stderr output (all lines joined)
@property (nonatomic, readonly, copy) NSString *errorOutput;

/// Execution duration in seconds
@property (nonatomic, readonly) NSTimeInterval duration;

@end

/// Line callback block: called for each line of output
/// @param line The output line (without newline)
/// @param isStdErr YES if from stderr, NO if from stdout
typedef void (^ISHShellLineCallback)(NSString *line, BOOL isStdErr);

/// Completion callback block: called when process exits
/// @param result Execution result containing exit code and outputs
typedef void (^ISHShellCompletionCallback)(ISHShellExecutionResult *result);

@interface ISHShellExecutor : NSObject

/// Execute a shell command with line-by-line output callback
/// @param command Shell command to execute (will be passed to /bin/sh -c)
/// @param lineCallback Called for each line of output (on main queue), can be nil
/// @param completion Called when process exits (on main queue), can be nil
/// @return Guest process PID, or negative error code on failure
+ (int)executeCommand:(NSString *)command
         lineCallback:(nullable ISHShellLineCallback)lineCallback
           completion:(nullable ISHShellCompletionCallback)completion;

/// Execute a shell command with array of arguments
/// @param executable Path to executable (e.g., "/bin/ls")
/// @param arguments Array of arguments (e.g., @[@"-la", @"/tmp"])
/// @param environment Dictionary of environment variables (nil = default)
/// @param lineCallback Called for each line of output (on main queue), can be nil
/// @param completion Called when process exits (on main queue), can be nil
/// @return Guest process PID, or negative error code on failure
+ (int)executeExecutable:(NSString *)executable
               arguments:(nullable NSArray<NSString *> *)arguments
             environment:(nullable NSDictionary<NSString *, NSString *> *)environment
            lineCallback:(nullable ISHShellLineCallback)lineCallback
              completion:(nullable ISHShellCompletionCallback)completion;

/// Execute with an opaque fs_context stamped on the new task group so the
/// fakefs path-translate hook can route /var/oases/* per session.
/// Passing 0 is equivalent to the method above.
+ (int)executeExecutable:(NSString *)executable
               arguments:(nullable NSArray<NSString *> *)arguments
             environment:(nullable NSDictionary<NSString *, NSString *> *)environment
               fsContext:(uint64_t)fsContext
            lineCallback:(nullable ISHShellLineCallback)lineCallback
              completion:(nullable ISHShellCompletionCallback)completion;

/// Execute a shell command and wait synchronously for completion
/// @param command Shell command to execute
/// @param timeout Maximum wait time in seconds (0 = no timeout)
/// @param lineCallback Called for each line of output, can be nil
/// @return Execution result
+ (ISHShellExecutionResult *)executeCommandSync:(NSString *)command
                                        timeout:(NSTimeInterval)timeout
                                   lineCallback:(nullable ISHShellLineCallback)lineCallback;

/// Waits on the calling thread for a command that `start` launches (the caller runs it on the
/// iSH runtime thread and returns the pid, or a negative error), with the same timeout and
/// kill behaviour as `executeCommandSync`. Only the launch occupies the runtime thread, so a
/// long command no longer queues every other shell, its own kill and any main-thread wait for
/// the runtime thread behind it. Must not be called on the main thread: completions are
/// delivered there.
+ (ISHShellExecutionResult *)waitForCommandStartedBy:(int (NS_NOESCAPE ^)(ISHShellCompletionCallback completion))start
                                             timeout:(NSTimeInterval)timeout;

/// Reaps exited children of the guest init (call on the iSH runtime thread, after a wait).
+ (int)reapInitChildren;

/// Kill a running process
/// @param pid Guest process PID (returned from execute methods)
/// @param signal Signal to send (default: SIGKILL)
/// @return YES if process was found and signaled
+ (BOOL)killProcess:(int)pid withSignal:(int)signal;

/// [Stage 0.3] Signal every task belonging to this shell_execute command —
/// matched by pgid OR by being a descendant of the root pid. The ancestry arm
/// is needed because busybox ash sometimes puts subshells into a fresh process
/// group (`setpgid(0,0)` for job control), which would leave `sleep` and
/// similar grandchildren invisible to a pgid-only sweep. Sends SIGTERM, then
/// SIGKILL stalking survivors ~200ms later. Refuses `pid <= 1` (init). Mirrors
/// OpenMinis `ISHShellExecutor.m::+killProcessGroup:`.
+ (void)killProcessGroup:(int)pid;

/// Finish a timed-out (or stopped) command's bookkeeping without waiting to be
/// told the process died.
///
/// [T-ish-shell-timeout-leak] Call this from EVERY timeout path, right after
/// killProcessGroup:. Teardown used to be driven solely by
/// ProcessExitedNotification, which does not arrive for a task that never
/// exits (blocked in a host call) or that the exit hook skips (an already-
/// reaped zombie). The context then stayed registered forever and, whenever a
/// surviving task still held the output pipe, both reader threads polled it
/// for the life of the process. Around thirty such timeouts exhaust the
/// concurrent reader queue's worker pool, after which no shell command
/// produces output at all.
///
/// The completion callback is delivered (on the main queue, as usual) with
/// error ISHShellExecutorErrorTimeout and whatever output was captured. Safe
/// to call when the command actually did exit in time, or more than once: a
/// context completes at most once and an unknown pid is ignored, so a timeout
/// racing a normal exit cannot double-invoke a completion.
///
/// @param pid Guest process PID whose context should be released
+ (void)finalizeTimedOutPid:(int)pid;

/// Snapshot of the leak-guard counters, e.g.
/// `activeExecutions=0 liveReaders=0`. `liveReaders` should return to 0
/// shortly after every command ends; a value that only climbs is the
/// [T-ish-shell-timeout-leak] recurring.
+ (NSString *)leakGuardStatus;

@end

/// A long-lived guest process with host-backed stdin/stdout/stderr pipes.
/// Unlike the one-shot executor, this object does not wait for process exit;
/// callers can exchange multiple newline-delimited protocol messages with the
/// same guest process.
@interface ISHShellInteractiveSession : NSObject

/// Guest PID assigned by iSH.
@property (nonatomic, readonly) int pid;

/// Start an executable and attach its standard streams to host pipes.
/// The method must be called on the dedicated iSH runtime thread.
+ (nullable instancetype)startExecutable:(NSString *)executable
                               arguments:(nullable NSArray<NSString *> *)arguments
                              environment:(nullable NSDictionary<NSString *, NSString *> *)environment
                                   error:(NSError * _Nullable * _Nullable)error;

/// Write bytes to guest stdin. Returns NO after the input pipe has closed.
- (BOOL)writeData:(NSData *)data;

/// Close guest stdin so a server can observe EOF.
- (void)closeInput;

/// Read one complete stdout line, waiting up to timeout seconds. The returned
/// line does not include its trailing newline. Nil means EOF or timeout.
- (nullable NSString *)readStdoutLineWithTimeout:(NSTimeInterval)timeout;

/// Read one complete stderr line, waiting up to timeout seconds.
- (nullable NSString *)readStderrLineWithTimeout:(NSTimeInterval)timeout;

/// Send a signal to the guest process and wake blocked readers.
- (void)terminateWithSignal:(int)signal;

@end

NS_ASSUME_NONNULL_END

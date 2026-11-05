//
//  DebugOffload.m
//  OasesChat
//
//  Native offload handler for `oases-debug`.
//  Most subcommands (viewTree / search / inspect / ls / readFile / writeFile /
//  shellExecute / screenshot / snapshot / overlay) call the in-app
//  DebugJSONRPC dispatcher directly (same process — iSH runs embedded) and are
//  therefore Debug-build-only (DebugLocalDispatch compiles out in Release).
//
//  The `logs` subcommand reads the app's own runtime log output (OSLogStore +
//  LoggingManager file) entirely in-process, never touching
//  DebugLocalDispatch (T-ios-oases-debug-logs-oslogstore). It used to ship in
//  Release too, but those logs carry base URLs, provider names and request
//  diagnostics that the agent — and a prompt injection driving it — must not
//  read on a user's device, so it is Debug-only as well (code review
//  2026-09-29, 3.6 P1).
//
//  The handler and registration are compiled in every configuration (Release
//  answers with a clear "requires a Debug build" error); every subcommand is
//  wrapped in `#if DEBUG`.
//

#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#if __has_include("OasesChat-Swift.h")
// [Stage 0] Oases target's generated Swift header. DebugLocalDispatch itself
// is not ported yet (Stage 5), and `DebugOffload.tool_main` reaches the
// dispatcher via `NSClassFromString(@"DebugLocalDispatch")` so it works
// without compile-time symbol binding — keep `#import` here only so the
// header compile visibility check passes once Stage 5 lands the real class.
#import "OasesChat-Swift.h"
#elif __has_include("Minis-Swift.h")
#import "Minis-Swift.h"
#elif __has_include("MinisApp-Swift.h")
#import "MinisApp-Swift.h"
#endif
#include "kernel/native_offload.h"
#include "NativeOffloadGate.h"
#include <unistd.h>

static NSString *const TOOL_NAME = @"oases-debug";

static NSString *const HELP_TEXT =
    @"oases-debug - Debug-build CLI for the in-app DebugJSONRPC dispatcher (in-process, no TCP)\n"
     "\n"
     "USAGE:\n"
     "  oases-debug <command> [options]\n"
     "\n"
     "COMMANDS:\n"
     "  discover                              List every JSON-RPC method (rpc.discover)\n"
     "  viewTree [--maxDepth N]               Dump the live view hierarchy\n"
     "  search <keyword> [--scope all|text|type]\n"
     "                                        Search views by text or class\n"
     "  inspect <address>                     Inspect a view by hex address\n"
     "  highlight <address> [--color red] [--duration 2.0]\n"
     "                                        Flash a colored overlay on a view\n"
     "  trace [--last]                        Dump recorded agent traces\n"
     "  ls [path] [--recursive] [--maxDepth N]\n"
     "                                        List sandbox files (default: Documents)\n"
     "  read <path> [--offset N] [--limit N] [--base64]\n"
     "                                        Read a sandbox file\n"
     "  write <path> --content <text> [--encoding utf8|base64] [--mode 0644]\n"
     "                                        Write a sandbox file\n"
     "  exec <command...>                     Run a shell command via DebugServer\n"
     "  screenshot [--scale N]                Capture a screenshot (returns PNG base64)\n"
     "  snapshot <list|get|clear|enable|disable> [--type markdown|messageList] [--id X]\n"
     "                                        Manage in-memory snapshot ring buffers\n"
     "  overlay <enable|disable|mode> [--mode all|byType|byTypePrefix|byAddress] [--type X] [--address X]\n"
     "                                        Control the debug-overlay layer\n"
     "  logs [--last N] [--minutes N] [--grep <keyword>]\n"
     "                                        Read the app's own runtime log (OSLogStore +\n"
     "                                        LoggingManager file).\n"
     "\n"
     "OPTIONS:\n"
     "  --help, -h        Show this help message\n"
     "  --compact         Minimize JSON output\n"
     "  -q, --quiet       Output only the data field\n"
     "\n"
     "EXAMPLES:\n"
     "  oases-debug discover\n"
     "  oases-debug viewTree --maxDepth 4\n"
     "  oases-debug search Chat --scope type\n"
     "  oases-debug inspect 0x10abc1234\n"
     "  oases-debug highlight 0x10abc1234 --color green --duration 1.5\n"
     "  oases-debug ls /var/oases/attachments\n"
     "  oases-debug read /var/oases/log.txt --limit 4096\n"
     "  oases-debug exec ls -la /var/oases\n"
     "  oases-debug snapshot list --type markdown\n"
     "  oases-debug overlay mode --mode byTypePrefix --type Selectable\n"
     "  oases-debug logs --grep StopDiag --last 50\n"
     "  oases-debug logs --minutes 5 --grep RetryDiag\n";

#if DEBUG

#pragma mark - Arg helpers (shared by all subcommands)

/// Pick up the first non-flag argument after the subcommand (positional[1]).
static NSString *_Nullable second_positional(int argc, char **argv) {
    NSArray<NSString *> *pos = noff_positional_args(argc, argv);
    return pos.count >= 2 ? pos[1] : nil;
}

/// Build NSNumber from a --flag string; nil if absent.
static NSNumber *_Nullable opt_int(int argc, char **argv, const char *name) {
    NSString *v = noff_find_arg(argc, argv, name);
    if (!v) return nil;
    return @(v.integerValue);
}

static NSNumber *_Nullable opt_double(int argc, char **argv, const char *name) {
    NSString *v = noff_find_arg(argc, argv, name);
    if (!v) return nil;
    return @(v.doubleValue);
}

#pragma mark - logs (in-process — no DebugLocalDispatch)

/// Read the app's own runtime log via the Swift OasesDebugLogReader bridge
/// (OSLogStore + LoggingManager file). Unlike every other subcommand this does
/// NOT route through DebugLocalDispatch.
static int cmd_logs(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    Class reader = NSClassFromString(@"OasesDebugLogReader");
    if (!reader) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"logs", NOFF_ERR_INTERNAL_ERROR,
                                             @"OasesDebugLogReader bridge unavailable");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    id shared = [reader performSelector:@selector(sharedInstance)];
    SEL sel = @selector(readLogsJSONWithLastN:minutes:grep:);
    if (!shared || ![shared respondsToSelector:sel]) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"logs", NOFF_ERR_INTERNAL_ERROR,
                                             @"OasesDebugLogReader.readLogsJSON missing");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSNumber *last = opt_int(argc, argv, "--last");
    NSNumber *minutes = opt_int(argc, argv, "--minutes");
    NSString *grep = noff_find_arg(argc, argv, "--grep");

    NSInteger lastN = last ? last.integerValue : 0;
    NSInteger minutesN = minutes ? minutes.integerValue : 0;

    NSString *(*imp)(id, SEL, NSInteger, NSInteger, NSString *) =
        (NSString *(*)(id, SEL, NSInteger, NSInteger, NSString *))[shared methodForSelector:sel];
    NSString *json = imp(shared, sel, lastN, minutesN, grep) ?: @"{}";

    // The bridge returns a JSON string; parse it back so emit wraps the
    // structured result in the standard noff envelope (matches emit_rpc shape).
    NSData *jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:NULL];
    id result = [parsed isKindOfClass:[NSDictionary class]] ? parsed : @{@"raw": json};

    NSDictionary *env = noff_json_envelope(TOOL_NAME, @"logs", result);
    noff_emit_json(stdout_fd, env, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

#pragma mark - In-process JSON-RPC dispatch (DEBUG only)

/// Invoke the in-process DebugJSONRPC dispatcher via the Swift bridge.
/// Returns the response body as a JSON string. Never nil — on bridge failure
/// returns a synthetic JSON-RPC error envelope so callers always get JSON.
static NSString *dispatch_local_rpc(NSString *envelopeJSON) {
    Class bridge = NSClassFromString(@"DebugLocalDispatch");
    if (!bridge) {
        return @"{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32001,\"message\":\"DebugLocalDispatch unavailable (Release build?)\"}}";
    }
    id shared = [bridge performSelector:@selector(sharedInstance)];
    if (!shared) {
        return @"{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32001,\"message\":\"DebugLocalDispatch.shared nil\"}}";
    }
    SEL sel = @selector(dispatchWithEnvelopeJSON:);
    if (![shared respondsToSelector:sel]) {
        return @"{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32001,\"message\":\"DebugLocalDispatch.dispatch missing\"}}";
    }
    NSString *(*imp)(id, SEL, NSString *) =
        (NSString *(*)(id, SEL, NSString *))[shared methodForSelector:sel];
    return imp(shared, sel, envelopeJSON) ?: @"";
}

#pragma mark - JSON-RPC invocation

/// Build a JSON-RPC envelope { jsonrpc, id, method, params } and dispatch it
/// in-process. Returns the parsed response dict (with `result` or `error`).
static NSDictionary *_Nullable call_rpc(NSString *method, NSDictionary *params, NSError **outError) {
    NSDictionary *envelope = @{
        @"jsonrpc": @"2.0",
        @"id": @1,
        @"method": method,
        @"params": params ?: @{},
    };
    NSError *encErr = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:&encErr];
    if (!bodyData) {
        if (outError) *outError = encErr;
        return nil;
    }
    NSString *bodyStr = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];
    NSString *resp = dispatch_local_rpc(bodyStr);

    NSError *parseErr = nil;
    NSData *respData = [resp dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = [NSJSONSerialization JSONObjectWithData:respData options:0 error:&parseErr];
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"OasesDebugOffload"
                                            code:-1
                                        userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"unexpected RPC response: %@", resp]}];
        }
        return nil;
    }
    return (NSDictionary *)parsed;
}

/// Emit either the RPC result or RPC error as a noff envelope.
static int emit_rpc(int stdout_fd, int stderr_fd, NSString *action,
                     NSString *method, NSDictionary *params,
                     BOOL compact, BOOL quiet) {
    NSError *err = nil;
    NSDictionary *resp = call_rpc(method, params, &err);
    if (!resp) {
        NSDictionary *errEnv = noff_json_error(TOOL_NAME, action,
                                                NOFF_ERR_INTERNAL_ERROR,
                                                err.localizedDescription ?: @"RPC dispatch failed");
        noff_emit_json(stdout_fd, errEnv, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    if (resp[@"error"]) {
        NSDictionary *errEnv = noff_json_error(TOOL_NAME, action,
                                                NOFF_ERR_INTERNAL_ERROR,
                                                [NSString stringWithFormat:@"%@", resp[@"error"]]);
        noff_emit_json(stdout_fd, errEnv, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    id result = resp[@"result"] ?: @{};
    NSDictionary *env = noff_json_envelope(TOOL_NAME, action, result);
    noff_emit_json(stdout_fd, env, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

#pragma mark - Subcommand dispatch (DEBUG-only, RPC-backed)

static int cmd_discover(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    return emit_rpc(stdout_fd, stderr_fd, @"discover", @"rpc.discover", @{}, compact, quiet);
}

static int cmd_viewTree(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    NSNumber *md = opt_int(argc, argv, "--maxDepth");
    if (md) params[@"maxDepth"] = md;
    return emit_rpc(stdout_fd, stderr_fd, @"viewTree", @"debug.viewTree", params, compact, quiet);
}

static int cmd_search(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *kw = second_positional(argc, argv);
    if (!kw) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"search", NOFF_ERR_INVALID_ARGS,
                                             @"search requires a keyword. Usage: oases-debug search <keyword> [--scope all|text|type]");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSMutableDictionary *params = [@{@"keyword": kw} mutableCopy];
    NSString *scope = noff_find_arg(argc, argv, "--scope");
    if (scope) params[@"scope"] = scope;
    return emit_rpc(stdout_fd, stderr_fd, @"search", @"debug.search", params, compact, quiet);
}

static int cmd_inspect(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *addr = second_positional(argc, argv);
    if (!addr) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"inspect", NOFF_ERR_INVALID_ARGS,
                                             @"inspect requires a view address. Usage: oases-debug inspect <address>");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    return emit_rpc(stdout_fd, stderr_fd, @"inspect", @"debug.inspect", @{@"address": addr}, compact, quiet);
}

static int cmd_highlight(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *addr = second_positional(argc, argv);
    if (!addr) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"highlight", NOFF_ERR_INVALID_ARGS,
                                             @"highlight requires a view address. Usage: oases-debug highlight <address> [--color red] [--duration 2.0]");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSMutableDictionary *params = [@{@"address": addr} mutableCopy];
    NSString *color = noff_find_arg(argc, argv, "--color");
    if (color) params[@"color"] = color;
    NSNumber *dur = opt_double(argc, argv, "--duration");
    if (dur) params[@"duration"] = dur;
    return emit_rpc(stdout_fd, stderr_fd, @"highlight", @"debug.highlight", params, compact, quiet);
}

static int cmd_trace(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    if (noff_has_flag(argc, argv, "--last")) params[@"last"] = @YES;
    return emit_rpc(stdout_fd, stderr_fd, @"trace", @"debug.agentTrace", params, compact, quiet);
}

static int cmd_ls(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *path = second_positional(argc, argv);
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    if (path) params[@"path"] = path;
    if (noff_has_flag(argc, argv, "--recursive")) params[@"recursive"] = @YES;
    NSNumber *md = opt_int(argc, argv, "--maxDepth");
    if (md) params[@"maxDepth"] = md;
    return emit_rpc(stdout_fd, stderr_fd, @"ls", @"debug.ls", params, compact, quiet);
}

static int cmd_read(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *path = second_positional(argc, argv);
    if (!path) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"read", NOFF_ERR_INVALID_ARGS,
                                             @"read requires a path. Usage: oases-debug read <path> [--offset N] [--limit N] [--base64]");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSMutableDictionary *params = [@{@"path": path} mutableCopy];
    NSNumber *off = opt_int(argc, argv, "--offset");
    if (off) params[@"offset"] = off;
    NSNumber *lim = opt_int(argc, argv, "--limit");
    if (lim) params[@"limit"] = lim;
    if (noff_has_flag(argc, argv, "--base64")) params[@"base64"] = @YES;
    return emit_rpc(stdout_fd, stderr_fd, @"read", @"debug.readFile", params, compact, quiet);
}

static int cmd_write(int argc, char **argv, int stdin_fd, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *path = second_positional(argc, argv);
    if (!path) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"write", NOFF_ERR_INVALID_ARGS,
                                             @"write requires a path. Usage: oases-debug write <path> --content <text> [--encoding utf8|base64] [--mode 0644]");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSString *content = noff_find_arg(argc, argv, "--content");
    if (!content) content = noff_read_stdin(stdin_fd);
    if (!content) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"write", NOFF_ERR_INVALID_ARGS,
                                             @"write requires --content <text> or stdin.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSMutableDictionary *params = [@{@"path": path, @"content": content} mutableCopy];
    NSString *enc = noff_find_arg(argc, argv, "--encoding");
    if (enc) params[@"encoding"] = enc;
    NSString *mode = noff_find_arg(argc, argv, "--mode");
    if (mode) params[@"mode"] = mode;
    return emit_rpc(stdout_fd, stderr_fd, @"write", @"debug.writeFile", params, compact, quiet);
}

static int cmd_exec(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSArray<NSString *> *pos = noff_positional_args(argc, argv);
    if (pos.count < 2) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"exec", NOFF_ERR_INVALID_ARGS,
                                             @"exec requires a command. Usage: oases-debug exec <command...>");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSArray *args = [pos subarrayWithRange:NSMakeRange(1, pos.count - 1)];
    NSString *cmd = [args componentsJoinedByString:@" "];
    return emit_rpc(stdout_fd, stderr_fd, @"exec", @"debug.shellExecute", @{@"command": cmd}, compact, quiet);
}

static int cmd_screenshot(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    NSNumber *scale = opt_double(argc, argv, "--scale");
    if (scale) params[@"scale"] = scale;
    return emit_rpc(stdout_fd, stderr_fd, @"screenshot", @"debug.screenshot", params, compact, quiet);
}

static int cmd_snapshot(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *sub = second_positional(argc, argv);
    if (!sub) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"snapshot", NOFF_ERR_INVALID_ARGS,
                                             @"snapshot requires a subcommand. Usage: oases-debug snapshot <list|get|clear|enable|disable> [--type markdown|messageList] [--id X]");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSString *type = noff_find_arg(argc, argv, "--type") ?: @"markdown";
    NSString *base = [type isEqualToString:@"messageList"]
        ? @"debug.messageListSnapshot"
        : @"debug.markdownSnapshot";

    NSString *method = nil;
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    if ([sub isEqualToString:@"enable"]) {
        method = [base stringByAppendingString:@".setEnabled"];
        params[@"enabled"] = @YES;
    } else if ([sub isEqualToString:@"disable"]) {
        method = [base stringByAppendingString:@".setEnabled"];
        params[@"enabled"] = @NO;
    } else if ([sub isEqualToString:@"list"]) {
        method = [base stringByAppendingString:@".list"];
    } else if ([sub isEqualToString:@"get"]) {
        method = [base stringByAppendingString:@".get"];
        NSString *sid = noff_find_arg(argc, argv, "--id");
        if (sid) params[@"id"] = sid;
    } else if ([sub isEqualToString:@"clear"]) {
        method = [base stringByAppendingString:@".clear"];
    } else {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"snapshot", NOFF_ERR_INVALID_ARGS,
                                             [NSString stringWithFormat:@"unknown snapshot subcommand '%@'. Valid: list|get|clear|enable|disable", sub]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    return emit_rpc(stdout_fd, stderr_fd,
                     [NSString stringWithFormat:@"snapshot.%@", sub],
                     method, params, compact, quiet);
}

static int cmd_overlay(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *sub = second_positional(argc, argv);
    if (!sub) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"overlay", NOFF_ERR_INVALID_ARGS,
                                             @"overlay requires a subcommand. Usage: oases-debug overlay <enable|disable|mode> [--mode all|byType|byTypePrefix|byAddress] [--type X] [--address X]");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSString *method = nil;
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    if ([sub isEqualToString:@"enable"]) {
        method = @"debug.debugOverlay.setEnabled";
        params[@"enabled"] = @YES;
    } else if ([sub isEqualToString:@"disable"]) {
        method = @"debug.debugOverlay.setEnabled";
        params[@"enabled"] = @NO;
    } else if ([sub isEqualToString:@"mode"]) {
        method = @"debug.debugOverlay.setMode";
        NSString *mode = noff_find_arg(argc, argv, "--mode");
        if (mode) params[@"mode"] = mode;
        NSString *type = noff_find_arg(argc, argv, "--type");
        if (type) params[@"type"] = type;
        NSString *addr = noff_find_arg(argc, argv, "--address");
        if (addr) params[@"address"] = addr;
    } else {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"overlay", NOFF_ERR_INVALID_ARGS,
                                             [NSString stringWithFormat:@"unknown overlay subcommand '%@'. Valid: enable|disable|mode", sub]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    return emit_rpc(stdout_fd, stderr_fd,
                     [NSString stringWithFormat:@"overlay.%@", sub],
                     method, params, compact, quiet);
}

#endif /* DEBUG — all subcommands */

#pragma mark - Top-level handler

static int debug_handler(int argc, char **argv,
                          int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"unknown",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"No command specified. Use --help for usage.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

#if DEBUG
    if ([subcmd isEqualToString:@"logs"])       return cmd_logs(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"discover"])   return cmd_discover(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"viewTree"])   return cmd_viewTree(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"search"])     return cmd_search(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"inspect"])    return cmd_inspect(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"highlight"])  return cmd_highlight(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"trace"])      return cmd_trace(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"ls"])         return cmd_ls(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"read"])       return cmd_read(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"write"])      return cmd_write(argc, argv, stdin_fd, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"exec"])       return cmd_exec(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"screenshot"]) return cmd_screenshot(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"snapshot"])   return cmd_snapshot(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"overlay"])    return cmd_overlay(argc, argv, stdout_fd, stderr_fd, compact, quiet);
#else
    // Release build: every subcommand is compiled out. Say so instead of a
    // bare "unknown command".
    {
        static NSString *const kDebugCmds = @"discover viewTree search inspect highlight trace ls read write exec screenshot snapshot overlay logs";
        if ([[kDebugCmds componentsSeparatedByString:@" "] containsObject:subcmd]) {
            NSDictionary *err = noff_json_error(TOOL_NAME, subcmd, NOFF_ERR_NOT_AVAILABLE,
                [NSString stringWithFormat:@"'%@' requires a Debug build; oases-debug is not available in Release builds.", subcmd]);
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_NOT_AVAILABLE;
        }
    }
#endif

    noff_emit_help(stderr_fd, HELP_TEXT);
    NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                         NOFF_ERR_INVALID_ARGS,
                                         [NSString stringWithFormat:@"Unknown command '%@'. Use --help for valid commands.", subcmd]);
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

void debug_offload_register(void) {
    int err = noff_register_gated_handler("oases-debug", debug_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/oases-debug");
        NSLog(@"NativeOffloads: oases-debug handler registered (subcommands DEBUG-only)");
    } else {
        NSLog(@"NativeOffloads: failed to register oases-debug handler (err=%d)", err);
    }
}

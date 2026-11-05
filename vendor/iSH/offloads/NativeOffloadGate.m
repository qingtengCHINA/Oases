//
//  NativeOffloadGate.m
//  OasesChat
//
//  See NativeOffloadGate.h. The kernel's handler signature carries no user
//  data, so each registered name gets its own trampoline slot; the slot index
//  tells the dispatcher which tool the kernel matched (by execve basename),
//  independent of whatever argv[0] the caller passed.
//

#import <Foundation/Foundation.h>
#import "NativeOffloadGate.h"
#import "NativeOffloadUtils.h"
#include "kernel/task.h"
#include <pthread.h>
#include <string.h>

#if __has_include("Oases_Chat-Swift.h")
#import "Oases_Chat-Swift.h"
#else
@interface OffloadGateBridge : NSObject
+ (NSDictionary * _Nonnull)authorizeWithCommand:(NSString * _Nonnull)command
                                      arguments:(NSArray<NSString *> * _Nonnull)arguments
                                      fsContext:(uint64_t)fsContext;
@end
#endif

#define NOFF_GATE_SLOTS 32
_Static_assert(NOFF_GATE_SLOTS == NATIVE_OFFLOAD_MAX,
               "one trampoline per kernel offload slot");

typedef struct {
    char name[64];
    native_handler_func handler;
} noff_gate_slot;

uint64_t noff_current_fs_context(void) {
    return (current && current->group) ? current->group->fs_context : 0;
}

static noff_gate_slot g_gate_slots[NOFF_GATE_SLOTS];
static int g_gate_slot_count = 0;
static pthread_mutex_t g_gate_lock = PTHREAD_MUTEX_INITIALIZER;

static int noff_gate_dispatch(int slot, int argc, char **argv,
                              int stdin_fd, int stdout_fd, int stderr_fd) {
    native_handler_func handler = g_gate_slots[slot].handler;
    const char *name = g_gate_slots[slot].name;
    if (!handler) return NOFF_EXIT_ERROR;

    @autoreleasepool {
        NSString *tool = [NSString stringWithUTF8String:name] ?: @"offload";
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithCapacity:argc > 1 ? argc - 1 : 0];
        for (int i = 1; i < argc; i++) {
            [arguments addObject:[NSString stringWithUTF8String:argv[i]] ?: @""];
        }
        // fs_context identifies the session whose shell started this process
        // (per-session grants); inherited across fork, 0 outside a session.
        uint64_t fsContext = (current && current->group) ? current->group->fs_context : 0;

        NSDictionary *decision = [OffloadGateBridge authorizeWithCommand:tool
                                                               arguments:arguments
                                                               fsContext:fsContext];
        if (![decision[@"allowed"] boolValue]) {
            NSString *message = decision[@"message"];
            if (message.length == 0) message = @"Permission denied.";
            BOOL compact = noff_has_flag(argc, argv, "--compact");
            BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");
            NSString *action = noff_get_subcommand(argc, argv) ?: @"permission";
            dprintf(stderr_fd, "%s: %s\n", name, message.UTF8String);
            noff_emit_json(stdout_fd,
                           noff_json_error(tool, action, @"permission_denied", message),
                           compact, quiet);
            return NOFF_EXIT_PERMISSION_DENIED;
        }
    }
    return handler(argc, argv, stdin_fd, stdout_fd, stderr_fd);
}

#define NOFF_GATE_TRAMPOLINE(n)                                                   \
    static int noff_gate_trampoline_##n(int argc, char **argv, int in, int out, int err) { \
        return noff_gate_dispatch(n, argc, argv, in, out, err);                   \
    }

NOFF_GATE_TRAMPOLINE(0)  NOFF_GATE_TRAMPOLINE(1)  NOFF_GATE_TRAMPOLINE(2)  NOFF_GATE_TRAMPOLINE(3)
NOFF_GATE_TRAMPOLINE(4)  NOFF_GATE_TRAMPOLINE(5)  NOFF_GATE_TRAMPOLINE(6)  NOFF_GATE_TRAMPOLINE(7)
NOFF_GATE_TRAMPOLINE(8)  NOFF_GATE_TRAMPOLINE(9)  NOFF_GATE_TRAMPOLINE(10) NOFF_GATE_TRAMPOLINE(11)
NOFF_GATE_TRAMPOLINE(12) NOFF_GATE_TRAMPOLINE(13) NOFF_GATE_TRAMPOLINE(14) NOFF_GATE_TRAMPOLINE(15)
NOFF_GATE_TRAMPOLINE(16) NOFF_GATE_TRAMPOLINE(17) NOFF_GATE_TRAMPOLINE(18) NOFF_GATE_TRAMPOLINE(19)
NOFF_GATE_TRAMPOLINE(20) NOFF_GATE_TRAMPOLINE(21) NOFF_GATE_TRAMPOLINE(22) NOFF_GATE_TRAMPOLINE(23)
NOFF_GATE_TRAMPOLINE(24) NOFF_GATE_TRAMPOLINE(25) NOFF_GATE_TRAMPOLINE(26) NOFF_GATE_TRAMPOLINE(27)
NOFF_GATE_TRAMPOLINE(28) NOFF_GATE_TRAMPOLINE(29) NOFF_GATE_TRAMPOLINE(30) NOFF_GATE_TRAMPOLINE(31)

static const native_handler_func g_gate_trampolines[NOFF_GATE_SLOTS] = {
    noff_gate_trampoline_0,  noff_gate_trampoline_1,  noff_gate_trampoline_2,  noff_gate_trampoline_3,
    noff_gate_trampoline_4,  noff_gate_trampoline_5,  noff_gate_trampoline_6,  noff_gate_trampoline_7,
    noff_gate_trampoline_8,  noff_gate_trampoline_9,  noff_gate_trampoline_10, noff_gate_trampoline_11,
    noff_gate_trampoline_12, noff_gate_trampoline_13, noff_gate_trampoline_14, noff_gate_trampoline_15,
    noff_gate_trampoline_16, noff_gate_trampoline_17, noff_gate_trampoline_18, noff_gate_trampoline_19,
    noff_gate_trampoline_20, noff_gate_trampoline_21, noff_gate_trampoline_22, noff_gate_trampoline_23,
    noff_gate_trampoline_24, noff_gate_trampoline_25, noff_gate_trampoline_26, noff_gate_trampoline_27,
    noff_gate_trampoline_28, noff_gate_trampoline_29, noff_gate_trampoline_30, noff_gate_trampoline_31,
};

int noff_register_gated_handler(const char *guest_name, native_handler_func handler) {
    if (!guest_name || !handler || strlen(guest_name) >= sizeof(g_gate_slots[0].name)) return -1;

    pthread_mutex_lock(&g_gate_lock);
    for (int i = 0; i < g_gate_slot_count; i++) {
        if (strcmp(g_gate_slots[i].name, guest_name) == 0) {
            g_gate_slots[i].handler = handler;
            pthread_mutex_unlock(&g_gate_lock);
            return 0;
        }
    }
    if (g_gate_slot_count >= NOFF_GATE_SLOTS) {
        pthread_mutex_unlock(&g_gate_lock);
        return -1;
    }
    int slot = g_gate_slot_count++;
    strlcpy(g_gate_slots[slot].name, guest_name, sizeof(g_gate_slots[slot].name));
    g_gate_slots[slot].handler = handler;
    pthread_mutex_unlock(&g_gate_lock);

    int err = native_offload_add_handler(guest_name, g_gate_trampolines[slot]);
    if (err != 0) {
        // Kernel registry full: the name never reaches this slot, so drop it.
        pthread_mutex_lock(&g_gate_lock);
        g_gate_slots[slot].handler = NULL;
        g_gate_slots[slot].name[0] = '\0';
        pthread_mutex_unlock(&g_gate_lock);
    }
    return err;
}

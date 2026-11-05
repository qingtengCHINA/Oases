//
//  OasesFakefsChangeBridge.h
//  OasesChat
//
//  Swift-facing bridge over iSH's fakefs change-notification hook.
//
//  `fakefs_record_change()` fires from realfs write/unlink/rename/truncate
//  when the path resolves under an active bind mount; events land in a
//  lock-protected ring buffer and are delivered in batches on a dedicated
//  serial queue. Sync V2's `SessionFileChangeTracker` consumes those batches
//  to decide which session files need uploading.
//
//  `fs/fake.h` is guarded by ISH_INTERNAL and pulls in the whole iSH header
//  tree, so this header re-declares only the shapes Swift needs.
//

#ifndef OasesFakefsChangeBridge_h
#define OasesFakefsChangeBridge_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Mirrors `FAKEFS_CHANGE_OP_*` in `fs/fake.h`. Values are part of the ABI.
typedef enum {
    OasesFakefsChangeOpWrite    = 0,
    OasesFakefsChangeOpUnlink   = 1,
    OasesFakefsChangeOpRename   = 2,   // destination of a rename
    OasesFakefsChangeOpTruncate = 3,
} OasesFakefsChangeOp;

/// One filesystem change, flattened for Swift.
typedef struct {
    const char *linuxPath;
    int         op;
    int64_t     timestampNs;   // mach_absolute_time() raw ticks
    /// `fs_context` stamped on the task group that issued the write. Maps back
    /// to a session id via `OasesFsRouter`; 0 when the path isn't
    /// session-routed (skills / memory / shared).
    uint64_t    fsContext;
} OasesFakefsChange;

/// Install the change consumer. The block runs on iSH's dedicated serial
/// queue, and `changes` is only valid for the duration of the call — copy
/// anything you need to keep. Replacing an existing consumer is allowed.
///
/// Safe to call before the runtime is up; iSH keeps the registration.
void oases_install_fakefs_change_handler(
    void (^handler)(const OasesFakefsChange *changes, int count));

#ifdef __cplusplus
}
#endif

#endif /* OasesFakefsChangeBridge_h */

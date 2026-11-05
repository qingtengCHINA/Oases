//
//  OasesFakefsChangeBridge.m
//  OasesChat
//

#import <Foundation/Foundation.h>
#include <stdint.h>
#include "OasesFakefsChangeBridge.h"

// `fs/fake.h` is ISH_INTERNAL-guarded and drags in the whole iSH header tree.
// `fakefs_install_change_consumer` ships in the prebuilt `libish.a` (verified
// with nm), so mirror just the struct + registration signature here — the same
// approach ISHRuntimeInit.m uses for the bind-mount entry points.
struct fakefs_change_event {
    char     linux_path[1024];
    int      op;
    int64_t  timestamp_ns;
    uint64_t fs_context;
};
typedef void (^fakefs_change_handler_t)(const struct fakefs_change_event *batch, int count);
void fakefs_install_change_consumer(fakefs_change_handler_t handler);

void oases_install_fakefs_change_handler(
    void (^handler)(const OasesFakefsChange *changes, int count)) {
    if (handler == NULL) {
        fakefs_install_change_consumer(NULL);
        return;
    }
    fakefs_change_handler_t wrapped = ^(const struct fakefs_change_event *batch, int count) {
        if (batch == NULL || count <= 0) return;
        // Flatten onto the Swift-facing shape. `linux_path` is a fixed-size
        // buffer inside a stack-owned batch, so the pointers below are only
        // valid for this call — same contract the underlying hook has, and
        // the header says so.
        OasesFakefsChange *flat = calloc((size_t)count, sizeof(OasesFakefsChange));
        if (flat == NULL) return;
        for (int i = 0; i < count; i++) {
            flat[i].linuxPath   = batch[i].linux_path;
            flat[i].op          = batch[i].op;
            flat[i].timestampNs = batch[i].timestamp_ns;
            flat[i].fsContext   = batch[i].fs_context;
        }
        handler(flat, count);
        free(flat);
    };
    fakefs_install_change_consumer(wrapped);
    NSLog(@"[ISHRuntime] fakefs change consumer installed");
}

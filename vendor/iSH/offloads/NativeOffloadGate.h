//
//  NativeOffloadGate.h
//  OasesChat
//
//  Single choke point for native-offload permissions. Every
//  `*_offload_register()` registers its handler through
//  `noff_register_gated_handler` instead of `native_offload_add_handler`; the
//  kernel then dispatches to a per-slot trampoline that asks the Swift
//  `OffloadGateBridge` (→ `OffloadPermissionManager`) for a decision before the
//  real handler runs. A denied call never reaches the handler: it exits 126
//  with a `permission_denied` JSON error on stdout and one line on stderr.
//
//  Not part of the Swift bridging header — it pulls in kernel headers.
//

#ifndef NativeOffloadGate_h
#define NativeOffloadGate_h

#include "kernel/native_offload.h"

/// Register `handler` for guest executable `guest_name` behind the permission
/// gate. Re-registering a name only swaps the handler (the kernel keeps the
/// first trampoline), so repeated bootstraps don't fill the 32-slot registry.
/// Returns 0 on success, -1 when the registry is full.
int noff_register_gated_handler(const char *guest_name, native_handler_func handler);

#endif /* NativeOffloadGate_h */

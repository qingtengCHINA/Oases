//
//  OasesChatOffloadBootstrap.h
//  [Stage 0.4] Aggregates all `*_offload_register()` calls — OpenMinis puts
//  this sequence at `iSH/ISHKernel.m::ish_boot_with_root` (around line 414-445)
//  right after `become_first_process` + device-node creation, before any
//  bind-mount. OasesChat's vendored iSH runtime (`ISHRuntimeInit.m`) handles
//  the fakefs boot separately from Swift, so we expose a single C entry that
//  `Services/Agent/ISHRuntimeBootstrap.swift` calls once at the end of
//  `bootstrap()` to register every offload in the internal handler table.
//
//  Why a single entry: each offload's `_offload_register` mutates the same
//  `static struct handler handlers[]` registry inside `native_offload.c`. If
//  some are skipped (because we add a feature later), the registry simply
//  doesn't have them and execve("/usr/bin/apple-XX") will fall through to
//  ENOSYS. No ordering between offloads is required — they all register
//  independent keys ("apple-<name>") in the same flat table.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Register every offload handler compiled into the OasesChat app target,
/// each behind the native-offload permission gate (NativeOffloadGate.h).
/// Only the first call registers; later calls are no-ops. Safe to call from
/// any thread.
void oases_offload_bootstrap(void);

NS_ASSUME_NONNULL_END
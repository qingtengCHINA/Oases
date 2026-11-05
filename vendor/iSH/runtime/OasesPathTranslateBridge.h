//
//  OasesPathTranslateBridge.h
//  Installs fakefs path-translate hook for per-session /var/oases routing.
//

#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift-friendly block: guest path + fs_context → host absolute path, or nil.
typedef NSString * _Nullable (^OasesPathTranslateBlock)(NSString *guestPath, uint64_t fsContext);

/// Install (or replace) the fakefs path-translate hook. Pass nil to clear.
void oases_install_path_translate_block(OasesPathTranslateBlock _Nullable block);

/// [Stage 0.3] Reverse hook (host→guest). Called from `realfa_getpath()` when
/// fakefs has resolved a bind-mounted fd's host APFS path back to a guest
/// path. Without this, readdir over per-session hook-routed buckets silently
/// fails the meta.db inode lookup (the OpenMinis `MinisFsRouter.reverse`
/// counterpart). Pass nil to clear.
typedef NSString * _Nullable (^OasesPathReverseBlock)(NSString *hostPath);

/// Install (or replace) the fakefs path-reverse hook. Pass nil to clear.
void oases_install_path_reverse_block(OasesPathReverseBlock _Nullable block);

NS_ASSUME_NONNULL_END
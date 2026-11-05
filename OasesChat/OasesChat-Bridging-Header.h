//
// OasesChat Swift ↔ Obj-C bridging header.
//
// Exposes the iSH runtime's `ISHShellExecutor` interface to Swift so
// `ShellTool.swift` can drop the NSClassFromString reflection path
// and call `[ISHShellExecutor executeCommandSync:timeout:lineCallback:]`
// directly once the static libraries are linked.
//

#import "ISHShellExecutor.h"
#import "DebugServer.h"
#import "ISHRuntimeInit.h"
#import "OasesPathTranslateBridge.h"
#import "OasesFakefsChangeBridge.h"

// [Stage 0.4] NativeOffload bootstrap + per-handler registration headers.
// `OasesChatOffloadBootstrap.h` is the only entry Swift actually calls,
// but importing the per-tool headers here keeps the .m files directly
// compilable from `vendor/iSH/offloads/` without per-file header search
// paths — Stage 4 batches add their own import lines here.
#import "OasesChatOffloadBootstrap.h"
#import "NativeOffloadUtils.h"
#import "ClipboardOffload.h"
#import "OpenOffload.h"
#import "DeviceOffload.h"
#import "SpeakOffload.h"
#import "NLPOffload.h"
#import "DebugOffload.h"
#import "CalendarOffload.h"
#import "RemindersOffload.h"
#import "NotificationOffload.h"
#import "PhotosOffload.h"
#import "MapsOffload.h"
#import "MediaOffload.h"
#import "SpeechOffload.h"
#import "VisionOffload.h"
#import "ConfigOffload.h"
#import "LocationOffload.h"
#import "NFCOffload.h"
#import "BluetoothOffload.h"
#import "WeatherOffload.h"
#import "AlarmOffload.h"
#import "FFmpegOffload.h"

// [P2] Diagnostics — POSIX signal handler that writes a crash marker before
// the process dies (MetricKit only reports on the NEXT launch).
#import "CrashSignalHandler.h"

// [P2] Debug-only ObjC helpers. Each is `#if DEBUG`-guarded internally, so the
// import is unconditional but the Release binary carries nothing.
#import "HangDetector.h"
#import "AutoTouch.h"
#import "AttributeQueryRecorder.h"
#import "FileHandleSafeWrite.h"
#import "ObjCExceptionCatcher.h"

// [Voice] Chinese word segmentation (cppjieba), used by TextSegmenter for
// the voice-correction vocabulary pipeline.
#import "JiebaWrapper.h"

// OpenMinis UITextKit guards (ported Shared/*.m)
#import "NSTextContainerSetSizeGuard.h"
#import "SafeKVCSetTrue.h"

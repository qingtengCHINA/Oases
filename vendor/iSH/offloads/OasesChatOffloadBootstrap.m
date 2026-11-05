//
//  OasesChatOffloadBootstrap.m
//

#import "OasesChatOffloadBootstrap.h"
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"

// [Stage 0.4] First batch — no extra framework entitlement required beyond
// what OasesChat has already declared, and no Swift module dependency. Each
// offload registers a "apple-<name>" guest executable handler.
#include "ClipboardOffload.h"
#include "OpenOffload.h"
#include "DeviceOffload.h"
#include "SpeakOffload.h"
#include "NLPOffload.h"
#include "DebugOffload.h"

// Second batch — system frameworks only (EventKit / UserNotifications /
// Photos / MapKit / MediaPlayer / Speech / Vision). Each needs its
// Info.plist usage string, declared via INFOPLIST_KEY_* in project.yml.
#include "CalendarOffload.h"
#include "RemindersOffload.h"
#include "NotificationOffload.h"
#include "PhotosOffload.h"
#include "MapsOffload.h"
#include "MediaOffload.h"
#include "SpeechOffload.h"
#include "VisionOffload.h"

// Config batch — bridges into Swift `ConfigOffloadBridge` (ConfigRegistry
// read/write + audit + confirmation gate).
#include "ConfigOffload.h"

// Third batch — each needs a new entitlement and/or Info.plist usage string
// (CoreNFC, WeatherKit, CoreLocation, CoreBluetooth, AlarmKit).
// See project.yml + OasesChat.entitlements.
#include "LocationOffload.h"
#include "NFCOffload.h"
#include "BluetoothOffload.h"
#include "WeatherOffload.h"
#include "AlarmOffload.h"

// Compiles to a no-op unless OASES_HAVE_FFMPEG is defined and
// FFmpeg.framework is linked — see README-FFmpeg.md.
#include "FFmpegOffload.h"

// Player — AVFoundation/AVKit. UI presented via MinisAudioPreviewView
// (stub in OasesChat/Features/Chat/Media/MediaPreviewPresenters.swift) +
// MinusVideoFullscreenPlayer (same file). GlobalAudioPlayer is the
// straight port from OpenMinis AudioPlayback.swift.
#include "PlayerOffload.h"

// ModelUse — bridges into Swift `ModelUseOffloadBridge` (calls
// ProviderConfigStore.resolvedAgentLoopEntries — already ported).
#include "ModelUseOffload.h"

// Sessions — bridges into Swift `SessionsOffloadBridge` (read-only paths
// hit `SessionsQueryEngine` on SwiftData; mutating paths return a
// structured "unsupported" until the ChatViewModel-driven send/retry
// surface lands).
#include "SessionsOffload.h"

// BrowserUse — bridges into Swift `BrowserUseOffloadBridge`, which is
// currently a structured "unsupported" stub. The real OpenMinis bridge
// drives a per-session `BrowserTabPool` (WKWebView pool) that has no
// counterpart in OasesChat yet.
#include "BrowserUseOffload.h"

static void oases_offload_register_all(void);

void oases_offload_bootstrap(void) {
    // OpenMinis sequence: see `iSH/ISHKernel.m` around lines 414-445.
    //
    // Every `*_offload_register()` goes through `noff_register_gated_handler`
    // (NativeOffloadGate.m), so each handler runs behind the permission gate.
    // New offloads must do the same — a direct `native_offload_add_handler`
    // call would bypass it.
    //
    // Both ISHRuntimeBootstrap and ISHKernel call this after boot. The kernel
    // registry appends (32 slots, first match wins), so run the sequence once.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        oases_offload_register_all();
    });
}

static void oases_offload_register_all(void) {
    clipboard_offload_register();
    open_offload_register();
    device_offload_register();
    speak_offload_register();
    nlp_offload_register();
    debug_offload_register();

    calendar_offload_register();
    reminders_offload_register();
    notification_offload_register();
    photos_offload_register();
    maps_offload_register();
    media_offload_register();
    speech_offload_register();
    vision_offload_register();

    config_offload_register();

    location_offload_register();
    nfc_offload_register();
    bluetooth_offload_register();
    weather_offload_register();
    alarm_offload_register();
    ffmpeg_offload_register();

    player_offload_register();
    model_use_offload_register();
    sessions_offload_register();
    browser_use_offload_register();
}
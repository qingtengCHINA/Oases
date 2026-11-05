//
//  OpenOffload.m
//  MinisApp
//
//  Native offload handler for `apple-open`.
//  Opens URLs, URL schemes, and system settings via UIApplication.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include "NativeOffloadGate.h"
#include <unistd.h>

static NSString *const TOOL_NAME = @"apple-open";

static NSString *const HELP_TEXT =
    @"apple-open - Open URLs, apps, and system settings\n"
     "\n"
     "USAGE:\n"
     "  apple-open <url>\n"
     "  apple-open settings\n"
     "\n"
     "ARGUMENTS:\n"
     "  <url>            URL to open (http, https, tel, mailto, sms, app schemes)\n"
     "  settings         Open this app's page in the iOS Settings app\n"
     "\n"
     "OPTIONS:\n"
     "  --help, -h       Show this help message\n"
     "  --compact        Minimize JSON output\n"
     "  -q, --quiet      Output only data field\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-open \"https://example.com\"\n"
     "  apple-open \"tel:10086\"\n"
     "  apple-open \"mailto:user@example.com\"\n"
     "  apple-open settings\n"
     "  apple-open \"maps://?q=coffee\"\n";

// `settings` opens this app's page in iOS Settings, the only public settings
// URL. Pages of the system Settings app have no public URL: `settings://<page>`
// falls back to this app's page, and the private `App-Prefs:` / `prefs:`
// schemes are refused (App Review 2.5.1).
static NSString *resolve_settings_url(NSString *input) {
    if ([input isEqualToString:@"settings"] || [input hasPrefix:@"settings://"]) {
        return UIApplicationOpenSettingsURLString;
    }
    return input;
}

static BOOL is_private_settings_url(NSString *input) {
    NSString *lower = input.lowercaseString;
    return [lower hasPrefix:@"app-prefs:"] || [lower hasPrefix:@"prefs:"];
}

static int open_handler(int argc, char **argv,
                         int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    // The URL is the first positional argument (subcommand position)
    NSString *urlArg = noff_get_subcommand(argc, argv);
    if (!urlArg) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"open",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"No URL specified. Use --help for usage.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    if (is_private_settings_url(urlArg)) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"open",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"System Settings pages have no public URL. Use `apple-open settings` to open this app's settings, or ask the user to open the page.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *resolvedURL = resolve_settings_url(urlArg);
    NSURL *url = [NSURL URLWithString:resolvedURL];
    if (!url) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"open",
                                             NOFF_ERR_INVALID_ARGS,
                                             [NSString stringWithFormat:@"Invalid URL: %@", urlArg]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    __block BOOL opened = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:url
                                         options:@{}
                               completionHandler:^(BOOL success) {
            opened = success;
            dispatch_semaphore_signal(sem);
        }];
    });

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    NSDictionary *data = @{
        @"url": urlArg,
        @"resolved_url": resolvedURL,
        @"opened": @(opened),
    };
    NSDictionary *result = noff_json_envelope(TOOL_NAME, @"open", data);
    noff_emit_json(stdout_fd, result, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

void open_offload_register(void) {
    int err = noff_register_gated_handler("apple-open", open_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-open");
        NSLog(@"NativeOffloads: apple-open handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-open handler (err=%d)", err);
    }
}

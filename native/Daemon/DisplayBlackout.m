#import "DisplayBlackout.h"
#import "DisplayWatcher.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

static NSString *ReadState(NSString *path) {
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

// O_EXCL pid file doubles as an instance lock. A stale file left behind by a
// crashed helper is removed and retried once.
static BOOL AcquirePIDLock(NSString *path, int *outFD) {
    for (int attempt = 0; attempt < 2; attempt++) {
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (fd >= 0) {
            NSString *content = [NSString stringWithFormat:@"%d\n", getpid()];
            size_t length = strlen(content.UTF8String);
            ssize_t written = write(fd, content.UTF8String, length);
            (void)written;
            *outFD = fd;
            return YES;
        }
        if (errno != EEXIST) return NO;
        NSString *text = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
        pid_t pid = (pid_t)[text integerValue];
        if (pid <= 0 || kill(pid, 0) != 0) {
            (void)unlink(path.fileSystemRepresentation);
            continue;
        }
        return NO; // Another blackout helper is already running.
    }
    return NO;
}

static NSArray<NSWindow *> *CreateBlackWindows(CGDirectDisplayID playerDisplayID) {
    NSMutableArray<NSWindow *> *windows = [NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (![number isKindOfClass:NSNumber.class]) continue;
        CGDirectDisplayID displayID = number.unsignedIntValue;
        if (displayID == playerDisplayID) continue;

        // NSScreen.frame already uses AppKit's bottom-left origin and global
        // display coordinates; CGDisplayBounds uses a top-left origin and must
        // not be used directly for an NSWindow frame.
        NSRect frame = screen.frame;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO
                                                         screen:screen];
        window.backgroundColor = NSColor.blackColor;
        window.opaque = YES;
        window.hasShadow = NO;
        window.level = NSMainMenuWindowLevel + 1;
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorStationary;
        [window setFrame:frame display:YES];
        [window orderFrontRegardless];
        [windows addObject:window];
    }
    return windows;
}

static void RemoveBlackWindows(NSMutableArray<NSWindow *> *windows) {
    for (NSWindow *window in windows) [window orderOut:nil];
    [windows removeAllObjects];
}

BOOL RunDisplayBlackout(NSString *statePath, NSString *pidPath) {
    int lockFD = -1;
    if (!AcquirePIDLock(pidPath, &lockFD)) {
        // Either another helper owns the screens or the pid file is unusable.
        // Both are harmless: the state file still controls the running helper.
        fprintf(stderr, "[INFO] Blackout helper already running or pid file unavailable; nothing to start\n");
        return YES;
    }

    NSApplication *application = [NSApplication sharedApplication];
    [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [application finishLaunching];

    pid_t parentPID = getppid();
    NSMutableArray<NSWindow *> *windows = [NSMutableArray array];
    CGDirectDisplayID currentPlayerDisplay = kCGNullDirectDisplay;
    BOOL windowsBuilt = NO;
    fprintf(stderr, "[INFO] Blackout helper started (pid %d)\n", getpid());

    while (YES) {
        @autoreleasepool {
            if (![ReadState(statePath) isEqualToString:@"1"]) break;
            if (kill(parentPID, 0) != 0) break;
            if ([NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.colliderli.iina"].count == 0) break;

            NSDictionary *diagnosis = ResolveIINAWindowTarget(YES);
            NSNumber *displayValue = diagnosis[@"displayID"];
            CGDirectDisplayID playerDisplay = [displayValue isKindOfClass:NSNumber.class]
                ? displayValue.unsignedIntValue : kCGNullDirectDisplay;

            // Only rebuild when the player display actually resolved and moved.
            // A background-Space player window (or a fullscreen transition)
            // resolves to no display; keep covering the last known screen so a
            // Space switch does not flash the other monitors back on.
            if (playerDisplay != kCGNullDirectDisplay &&
                (!windowsBuilt || playerDisplay != currentPlayerDisplay)) {
                RemoveBlackWindows(windows);
                [windows addObjectsFromArray:CreateBlackWindows(playerDisplay)];
                currentPlayerDisplay = playerDisplay;
                windowsBuilt = YES;
                fprintf(stderr, "[INFO] Blackout windows rebuilt (player display %u, %lu covered)\n",
                        playerDisplay, (unsigned long)windows.count);
            }

            // Keep the AppKit run loop alive so the windows can draw, while
            // still polling the state file and the player's screen.
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
            while (deadline.timeIntervalSinceNow > 0) {
                @autoreleasepool {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                }
            }
        }
    }

    RemoveBlackWindows(windows);
    if (lockFD >= 0) (void)close(lockFD);
    (void)unlink(pidPath.fileSystemRepresentation);
    fprintf(stderr, "[INFO] Blackout helper stopped\n");
    return YES;
}

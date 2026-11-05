#import "DisplayWatcher.h"
#import <AppKit/AppKit.h>
#import "../DisplayDiscovery.h"
#import "DisplaySocketServer.h"
#import <ApplicationServices/ApplicationServices.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <fcntl.h>
#import <signal.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <time.h>

static BOOL SendLine(int fd, NSDictionary *message, NSDictionary **response) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!json) return NO;
    NSMutableData *line = [json mutableCopy];
    const uint8_t newline = '\n';
    [line appendBytes:&newline length:1];
    const uint8_t *bytes = line.bytes;
    size_t left = line.length;
    while (left) {
        ssize_t count = send(fd, bytes, left, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        bytes += count; left -= (size_t)count;
    }
    NSMutableData *received = [NSMutableData data];
    uint8_t byte;
    while (recv(fd, &byte, 1, 0) == 1 && byte != '\n') {
        if (received.length >= 65536) return NO;
        [received appendBytes:&byte length:1];
    }
    id decoded = [NSJSONSerialization JSONObjectWithData:received options:0 error:nil];
    if (![decoded isKindOfClass:NSDictionary.class]) return NO;
    if (response) *response = decoded;
    return YES;
}

static NSString *TargetIdentityForFrontmostIINAWindow(void) {
    NSArray<NSRunningApplication *> *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.colliderli.iina"];
    if (!apps.count) return nil;
    NSMutableSet<NSNumber *> *pids = [NSMutableSet set];
    for (NSRunningApplication *app in apps) [pids addObject:@(app.processIdentifier)];
    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!windows) return nil;
    CGRect titlebar = CGRectNull;
    for (NSDictionary *window in CFBridgingRelease(windows)) {
        if (![pids containsObject:window[(id)kCGWindowOwnerPID]] || [window[(id)kCGWindowLayer] intValue] != 0) continue;
        NSDictionary *boundsValue = window[(id)kCGWindowBounds];
        if (![boundsValue isKindOfClass:NSDictionary.class]) continue;
        CGRect frame = CGRectMake([boundsValue[@"X"] doubleValue], [boundsValue[@"Y"] doubleValue],
                                  [boundsValue[@"Width"] doubleValue], [boundsValue[@"Height"] doubleValue]);
        if (CGRectIsEmpty(frame) || CGRectIsNull(frame)) continue;
        // WindowServer bounds include the titlebar. Use only its top 32 pt band for screen assignment.
        titlebar = CGRectMake(frame.origin.x, frame.origin.y, frame.size.width, MIN(32.0, frame.size.height));
        break; // WindowServer returns front-to-back order.
    }
    if (CGRectIsNull(titlebar)) return nil;

    uint32_t count = 0;
    if (CGGetActiveDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) return nil;
    CGDirectDisplayID *ids = calloc(count, sizeof(CGDirectDisplayID));
    if (!ids) return nil;
    if (CGGetActiveDisplayList(count, ids, &count) != kCGErrorSuccess) { free(ids); return nil; }
    CGDirectDisplayID selected = kCGNullDirectDisplay;
    CGFloat bestIntersection = 0;
    for (uint32_t i = 0; i < count; i++) {
        CGRect intersection = CGRectIntersection(titlebar, CGDisplayBounds(ids[i]));
        CGFloat area = CGRectIsNull(intersection) ? 0 : intersection.size.width * intersection.size.height;
        if (area > bestIntersection) { bestIntersection = area; selected = ids[i]; }
    }
    free(ids);
    if (selected == kCGNullDirectDisplay || bestIntersection <= 0) return nil;
    NSError *error = nil;
    for (DisplayInfo *display in DiscoverDisplays(&error)) {
        if (display.displayID == selected && display.identity.length) return display.identity;
    }
    return nil;
}

static BOOL StartDaemon(NSString *helperPath) {
    pid_t child = fork();
    if (child != 0) return child > 0;
    setsid();
    int nullFD = open("/dev/null", O_RDWR);
    if (nullFD >= 0) { dup2(nullFD, STDIN_FILENO); dup2(nullFD, STDOUT_FILENO); dup2(nullFD, STDERR_FILENO); if (nullFD > 2) close(nullFD); }
    execl(helperPath.fileSystemRepresentation, helperPath.fileSystemRepresentation, "daemon", (char *)NULL);
    _exit(127);
}

BOOL RunDisplayWatcher(NSString *helperPath, NSString *socketPath, NSString *heartbeatPath, NSError **error) {
    if (!StartDaemon(helperPath)) {
        if (error) *error = [NSError errorWithDomain:@"DisplayWatcher" code:errno userInfo:@{NSLocalizedDescriptionKey: @"Unable to launch display daemon"}];
        return NO;
    }
    int fd = -1;
    for (int attempt = 0; attempt < 100; attempt++) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd >= 0) {
            struct sockaddr_un address = {};
            address.sun_len = sizeof(address); address.sun_family = AF_UNIX;
            if (socketPath.fileSystemRepresentation && strlen(socketPath.fileSystemRepresentation) < sizeof(address.sun_path)) {
                strlcpy(address.sun_path, socketPath.fileSystemRepresentation, sizeof(address.sun_path));
                if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) break;
            }
            close(fd); fd = -1;
        }
        usleep(100000);
    }
    if (fd < 0) { if (error) *error = [NSError errorWithDomain:@"DisplayWatcher" code:ECONNREFUSED userInfo:@{NSLocalizedDescriptionKey: @"Unable to connect to display daemon"}]; return NO; }
    NSDictionary *reply = nil;
    if (!SendLine(fd, @{ @"type": @"HELLO", @"requestId": @1 }, &reply) || ![reply[@"success"] boolValue]) { close(fd); return NO; }
    NSString *lastObserved = @"__initial__";
    BOOL lastRequestSucceeded = NO;
    time_t retryAfter = 0;
    NSUInteger requestID = 2;
    pid_t parentPID = getppid();
    while (kill(parentPID, 0) == 0) {
        struct stat heartbeatInfo;
        if (stat(heartbeatPath.fileSystemRepresentation, &heartbeatInfo) != 0 ||
            time(NULL) - heartbeatInfo.st_mtime > 3) break;
        @autoreleasepool {
            NSString *identity = TargetIdentityForFrontmostIINAWindow();
            NSString *normalized = identity ?: @"";
            BOOL targetChanged = ![normalized isEqualToString:lastObserved];
            if (targetChanged || (!lastRequestSucceeded && time(NULL) >= retryAfter)) {
                lastObserved = normalized;
                NSDictionary *message = @{ @"type": @"SET_TARGET", @"requestId": @(requestID++), @"identity": identity ?: NSNull.null };
                if (!SendLine(fd, message, &reply)) {
                    fprintf(stderr, "[ERROR] Socket request failed while setting target\n");
                    break;
                }
                lastRequestSucceeded = [reply[@"success"] boolValue];
                if (lastRequestSucceeded) {
                    fprintf(stderr, "[INFO] Target set to %s\n", (identity ?: @"<none>").UTF8String);
                } else {
                    NSString *messageText = [reply[@"message"] isKindOfClass:NSString.class] ? reply[@"message"] : @"Daemon rejected SET_TARGET";
                    fprintf(stderr, "[ERROR] Unable to set target %s: %s\n",
                            (identity ?: @"<none>").UTF8String, messageText.UTF8String);
                    retryAfter = time(NULL) + 2;
                }
            }
        }
        usleep(500000);
    }
    close(fd); // The daemon restores managed displays when this session ends.
    return YES;
}

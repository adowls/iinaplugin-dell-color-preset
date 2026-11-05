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
#import <time.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <sys/time.h>
#import <CommonCrypto/CommonDigest.h>

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

static BOOL SocketWriteAll(int fd, const void *buffer, size_t length) {
    const uint8_t *bytes = buffer;
    while (length > 0) {
        ssize_t count = send(fd, bytes, length, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        bytes += count;
        length -= (size_t)count;
    }
    return YES;
}

static BOOL SocketReadAll(int fd, void *buffer, size_t length) {
    uint8_t *bytes = buffer;
    while (length > 0) {
        ssize_t count = recv(fd, bytes, length, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        bytes += count;
        length -= (size_t)count;
    }
    return YES;
}

static int ConnectPluginHeartbeatSocket(uint16_t port, NSError **error) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:@"DisplayWatcher" code:errno userInfo:@{NSLocalizedDescriptionKey: @"Unable to create heartbeat TCP socket"}];
        return -1;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct timeval timeout = { .tv_sec = 3, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    struct sockaddr_in address = {};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        int code = errno;
        close(fd);
        if (error) *error = [NSError errorWithDomain:@"DisplayWatcher" code:code userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unable to connect to plugin heartbeat server: %s", strerror(code)]}];
        return -1;
    }

    uint8_t randomKey[16];
    arc4random_buf(randomKey, sizeof(randomKey));
    NSString *key = [[NSData dataWithBytes:randomKey length:sizeof(randomKey)] base64EncodedStringWithOptions:0];
    NSString *request = [NSString stringWithFormat:
        @"GET / HTTP/1.1\r\nHost: 127.0.0.1:%u\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %@\r\nSec-WebSocket-Version: 13\r\n\r\n",
        port, key];
    NSData *requestData = [request dataUsingEncoding:NSUTF8StringEncoding];
    if (!SocketWriteAll(fd, requestData.bytes, requestData.length)) {
        int code = errno ?: EIO;
        close(fd);
        if (error) *error = [NSError errorWithDomain:@"DisplayWatcher" code:code userInfo:@{NSLocalizedDescriptionKey: @"Unable to send WebSocket handshake"}];
        return -1;
    }

    NSMutableData *headers = [NSMutableData data];
    const uint8_t endOfHeaders[] = { '\r', '\n', '\r', '\n' };
    while (headers.length < 16384) {
        uint8_t byte = 0;
        if (!SocketReadAll(fd, &byte, 1)) break;
        [headers appendBytes:&byte length:1];
        if (headers.length >= sizeof(endOfHeaders) &&
            memcmp((const uint8_t *)headers.bytes + headers.length - sizeof(endOfHeaders), endOfHeaders, sizeof(endOfHeaders)) == 0) break;
    }
    NSString *headerText = [[NSString alloc] initWithData:headers encoding:NSUTF8StringEncoding];
    NSString *expectedAcceptSource = [key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];
    NSData *acceptSourceData = [expectedAcceptSource dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(acceptSourceData.bytes, (CC_LONG)acceptSourceData.length, digest);
    NSString *expectedAccept = [[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0];
    BOOL validUpgrade = [headerText hasPrefix:@"HTTP/1.1 101 "];
    BOOL validAccept = NO;
    for (NSString *line in [headerText componentsSeparatedByString:@"\r\n"]) {
        if ([[line lowercaseString] hasPrefix:@"sec-websocket-accept:"]) {
            NSString *actual = [[line componentsSeparatedByString:@":"] lastObject];
            validAccept = [[actual stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] isEqualToString:expectedAccept];
            break;
        }
    }
    if (!validUpgrade || !validAccept) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:@"DisplayWatcher" code:EPROTO userInfo:@{NSLocalizedDescriptionKey: @"Plugin returned an invalid WebSocket handshake"}];
        return -1;
    }
    return fd;
}

static BOOL SendWebSocketFrame(int fd, uint8_t opcode, NSData *payload) {
    NSUInteger length = payload.length;
    NSMutableData *frame = [NSMutableData data];
    uint8_t first = (uint8_t)(0x80 | (opcode & 0x0f));
    [frame appendBytes:&first length:1];
    if (length < 126) {
        uint8_t second = (uint8_t)(0x80 | length);
        [frame appendBytes:&second length:1];
    } else if (length <= UINT16_MAX) {
        uint8_t second = 0x80 | 126;
        uint16_t networkLength = htons((uint16_t)length);
        [frame appendBytes:&second length:1];
        [frame appendBytes:&networkLength length:sizeof(networkLength)];
    } else {
        return NO;
    }
    uint8_t mask[4];
    arc4random_buf(mask, sizeof(mask));
    [frame appendBytes:mask length:sizeof(mask)];
    const uint8_t *source = payload.bytes;
    NSMutableData *masked = [NSMutableData dataWithLength:length];
    uint8_t *destination = masked.mutableBytes;
    for (NSUInteger i = 0; i < length; i++) destination[i] = source[i] ^ mask[i % sizeof(mask)];
    [frame appendData:masked];
    return SocketWriteAll(fd, frame.bytes, frame.length);
}

static NSString *ReadWebSocketMessage(int fd) {
    NSMutableData *message = [NSMutableData data];
    BOOL readingData = NO;
    while (message.length <= 65536) {
        uint8_t header[2];
        if (!SocketReadAll(fd, header, sizeof(header))) return nil;
        BOOL final = (header[0] & 0x80) != 0;
        uint8_t opcode = header[0] & 0x0f;
        BOOL masked = (header[1] & 0x80) != 0;
        uint64_t length = header[1] & 0x7f;
        if (length == 126) {
            uint16_t networkLength = 0;
            if (!SocketReadAll(fd, &networkLength, sizeof(networkLength))) return nil;
            length = ntohs(networkLength);
        } else if (length == 127) {
            uint64_t networkLength = 0;
            if (!SocketReadAll(fd, &networkLength, sizeof(networkLength))) return nil;
            length = CFSwapInt64BigToHost(networkLength);
        }
        if (length > 65536 || message.length + length > 65536) return nil;
        uint8_t mask[4] = {};
        if (masked && !SocketReadAll(fd, mask, sizeof(mask))) return nil;
        NSMutableData *payload = [NSMutableData dataWithLength:(NSUInteger)length];
        if (length && !SocketReadAll(fd, payload.mutableBytes, (size_t)length)) return nil;
        if (masked) {
            uint8_t *bytes = payload.mutableBytes;
            for (NSUInteger i = 0; i < payload.length; i++) bytes[i] ^= mask[i % sizeof(mask)];
        }
        if (opcode == 0x8) return nil;
        if (opcode == 0x9) {
            if (!SendWebSocketFrame(fd, 0xA, payload)) return nil;
            continue;
        }
        if (opcode == 0xA) continue;
        if (opcode == 0x1 || opcode == 0x2) readingData = YES;
        else if (opcode != 0x0 || !readingData) return nil;
        [message appendData:payload];
        if (final) return [[NSString alloc] initWithData:message encoding:NSUTF8StringEncoding];
    }
    return nil;
}

static BOOL SendPluginHeartbeat(int fd, NSString *token, NSUInteger sequence, NSString **failure) {
    NSDictionary *ping = @{ @"type": @"PING", @"token": token, @"sequence": @(sequence) };
    NSData *json = [NSJSONSerialization dataWithJSONObject:ping options:0 error:nil];
    if (!json || !SendWebSocketFrame(fd, 0x1, json)) {
        if (failure) *failure = @"Unable to send WebSocket PING";
        return NO;
    }
    NSString *text = ReadWebSocketMessage(fd);
    if (!text) {
        if (failure) *failure = @"No PONG received before socket timeout or disconnect";
        return NO;
    }
    NSData *replyData = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *response = [NSJSONSerialization JSONObjectWithData:replyData options:0 error:nil];
    BOOL valid = [response isKindOfClass:NSDictionary.class] &&
                 [response[@"type"] isEqual:@"PONG"] &&
                 [response[@"token"] isEqual:token] &&
                 [response[@"sequence"] isEqual:@(sequence)];
    if (!valid && failure) *failure = @"Plugin returned an invalid PONG";
    return valid;
}

BOOL RunDisplayWatcher(NSString *helperPath, NSString *socketPath, uint16_t heartbeatPort, NSString *heartbeatToken, NSError **error) {
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

    NSError *heartbeatError = nil;
    int heartbeatFD = ConnectPluginHeartbeatSocket(heartbeatPort, &heartbeatError);
    if (heartbeatFD < 0) {
        close(fd);
        if (error) *error = heartbeatError;
        return NO;
    }

    NSString *lastObserved = @"__initial__";
    BOOL lastRequestSucceeded = NO;
    time_t retryAfter = 0;
    NSUInteger requestID = 2;
    NSUInteger heartbeatSequence = 1;
    time_t nextHeartbeat = 0;
    pid_t parentPID = getppid();
    while (kill(parentPID, 0) == 0) {
        time_t now = time(NULL);
        if (now >= nextHeartbeat) {
            NSString *heartbeatFailure = nil;
            if (!SendPluginHeartbeat(heartbeatFD, heartbeatToken, heartbeatSequence++, &heartbeatFailure)) {
                fprintf(stderr, "[ERROR] Plugin heartbeat failed: %s\n", heartbeatFailure.UTF8String);
                break;
            }
            nextHeartbeat = time(NULL) + 1;
        }
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
    close(heartbeatFD);
    close(fd); // The daemon restores managed displays when this session ends.
    return YES;
}

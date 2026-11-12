#import "DisplaySocketServer.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <time.h>

static const NSUInteger kMaximumMessageLength = 65536;
static NSString * const SocketErrorDomain = @"DisplaySocketServer";

static NSError *SocketError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:SocketErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSString *DefaultDisplaySocketPath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!support.length) support = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    return [[support stringByAppendingPathComponent:@"IINA/plugins/dell-color-preset/run"]
            stringByAppendingPathComponent:@"helper.sock"];
}

static BOOL EnsurePrivateDirectory(NSString *path, NSError **error) {
    NSError *fileError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:path
                                   withIntermediateDirectories:YES
                                                    attributes:@{NSFilePosixPermissions: @0700}
                                                         error:&fileError]) {
        if (error) *error = fileError;
        return NO;
    }
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != getuid()) {
        if (error) *error = SocketError(errno ?: EPERM, @"Socket directory must be a real directory owned by the current user");
        return NO;
    }
    if (chmod(path.fileSystemRepresentation, 0700) != 0) {
        if (error) *error = SocketError(errno, @"Unable to set socket directory permissions to 0700");
        return NO;
    }
    return YES;
}

static BOOL WriteAll(int fd, const void *data, size_t length) {
    const uint8_t *cursor = data;
    while (length > 0) {
        ssize_t written = send(fd, cursor, length, 0);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        cursor += written;
        length -= (size_t)written;
    }
    return YES;
}

static BOOL WriteJSONLine(int fd, NSDictionary *object) {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingFragmentsAllowed error:&error];
    if (!json || json.length > kMaximumMessageLength) return NO;
    NSMutableData *line = [json mutableCopy];
    const uint8_t newline = '\n';
    [line appendBytes:&newline length:1];
    return WriteAll(fd, line.bytes, line.length);
}

static NSDictionary *ErrorResponse(id requestID, NSString *code, NSString *message) {
    NSMutableDictionary *response = [@{@"type": @"ERROR", @"code": code, @"message": message} mutableCopy];
    if (requestID) response[@"requestId"] = requestID;
    return response;
}

@interface DisplaySocketServer ()
@property(nonatomic, strong) DisplayStateManager *stateManager;
@property(nonatomic, copy) NSString *socketPath;
@property(nonatomic, assign) NSTimeInterval initialRetryInterval;
@property(nonatomic, assign) NSTimeInterval maximumRetryInterval;
@property(nonatomic, assign) BOOL didHello;
@end

@implementation DisplaySocketServer
- (instancetype)initWithStateManager:(DisplayStateManager *)stateManager socketPath:(NSString *)socketPath {
    return [self initWithStateManager:stateManager socketPath:socketPath initialRetryInterval:1.0 maximumRetryInterval:30.0];
}

- (instancetype)initWithStateManager:(DisplayStateManager *)stateManager
                          socketPath:(NSString *)socketPath
               initialRetryInterval:(NSTimeInterval)initialRetryInterval
               maximumRetryInterval:(NSTimeInterval)maximumRetryInterval {
    self = [super init];
    if (self) {
        _stateManager = stateManager;
        _socketPath = [socketPath copy];
        _initialRetryInterval = MAX(0.01, initialRetryInterval);
        _maximumRetryInterval = MAX(_initialRetryInterval, maximumRetryInterval);
    }
    return self;
}

- (NSDictionary *)responseForMessage:(NSDictionary *)message shouldClose:(BOOL *)shouldClose {
    id requestID = message[@"requestId"];
    id typeValue = message[@"type"];
    if (![typeValue isKindOfClass:NSString.class]) return ErrorResponse(requestID, @"INVALID_MESSAGE", @"Message type must be a string");
    NSString *type = typeValue;
    if (![requestID isKindOfClass:NSNumber.class] && ![requestID isKindOfClass:NSString.class]) {
        return ErrorResponse(nil, @"INVALID_MESSAGE", @"requestId must be a string or number");
    }

    if ([type isEqualToString:@"HELLO"]) {
        if (self.didHello) return ErrorResponse(requestID, @"DUPLICATE_HELLO", @"HELLO has already completed for this session");
        self.didHello = YES;
        return @{@"type": @"HELLO_ACK", @"requestId": requestID, @"success": @YES, @"daemonVersion": @"1.0"};
    }
    if (!self.didHello) return ErrorResponse(requestID, @"HELLO_REQUIRED", @"Send HELLO before other requests");

    if ([type isEqualToString:@"SET_TARGET"]) {
        id identityValue = message[@"identity"];
        if (identityValue != NSNull.null && (![identityValue isKindOfClass:NSString.class] || [identityValue length] == 0 || [identityValue length] > 512)) {
            return ErrorResponse(requestID, @"INVALID_IDENTITY", @"identity must be a non-empty string or null");
        }
        NSError *stateError = nil;
        NSString *identity = identityValue == NSNull.null ? nil : identityValue;
        BOOL success = [self.stateManager setTargetIdentity:identity error:&stateError];
        if (!success) return ErrorResponse(requestID, @"TARGET_FAILED", stateError.localizedDescription ?: @"Unable to acquire target display");
        return @{@"type": @"RESULT", @"requestId": requestID, @"success": @YES,
                 @"identity": identity ?: NSNull.null, @"state": identity ? @"movie" : @"released"};
    }
    if ([type isEqualToString:@"STATUS"]) {
        NSMutableDictionary *response = [[self.stateManager statusDictionary] mutableCopy];
        response[@"type"] = @"STATUS_RESULT";
        response[@"requestId"] = requestID;
        return response;
    }
    if ([type isEqualToString:@"QUIT"]) {
        *shouldClose = YES;
        return @{@"type": @"RESULT", @"requestId": requestID, @"success": @YES, @"state": @"disconnecting"};
    }
    return ErrorResponse(requestID, @"UNKNOWN_MESSAGE", [NSString stringWithFormat:@"Unknown message type %@", type]);
}

- (BOOL)serveClient:(int)clientFD {
    self.didHello = NO;
    NSMutableData *pending = [NSMutableData data];
    uint8_t chunk[4096];
    while (YES) {
        ssize_t received = recv(clientFD, chunk, sizeof(chunk), 0);
        if (received < 0 && errno == EINTR) continue;
        if (received <= 0) return YES;
        [pending appendBytes:chunk length:(NSUInteger)received];
        if (pending.length > kMaximumMessageLength && memchr(pending.bytes, '\n', pending.length) == NULL) {
            WriteJSONLine(clientFD, ErrorResponse(nil, @"MESSAGE_TOO_LARGE", @"JSON line exceeds 65536 bytes"));
            return NO;
        }
        while (YES) {
            const uint8_t *bytes = pending.bytes;
            const uint8_t *newline = memchr(bytes, '\n', pending.length);
            if (!newline) break;
            NSUInteger lineLength = (NSUInteger)(newline - bytes);
            if (lineLength > kMaximumMessageLength) {
                WriteJSONLine(clientFD, ErrorResponse(nil, @"MESSAGE_TOO_LARGE", @"JSON line exceeds 65536 bytes"));
                return NO;
            }
            NSData *line = [NSData dataWithBytes:bytes length:lineLength];
            [pending replaceBytesInRange:NSMakeRange(0, lineLength + 1) withBytes:NULL length:0];
            NSError *jsonError = nil;
            id decoded = [NSJSONSerialization JSONObjectWithData:line options:NSJSONReadingFragmentsAllowed error:&jsonError];
            if (![decoded isKindOfClass:NSDictionary.class]) {
                if (!WriteJSONLine(clientFD, ErrorResponse(nil, @"INVALID_JSON", jsonError.localizedDescription ?: @"Each line must contain a JSON object"))) return NO;
                continue;
            }
            BOOL shouldClose = NO;
            NSDictionary *response = [self responseForMessage:decoded shouldClose:&shouldClose];
            if (!WriteJSONLine(clientFD, response)) return NO;
            if (shouldClose) return YES;
        }
        if (pending.length > kMaximumMessageLength) {
            WriteJSONLine(clientFD, ErrorResponse(nil, @"MESSAGE_TOO_LARGE", @"JSON line exceeds 65536 bytes"));
            return NO;
        }
    }
}

- (BOOL)runWithError:(NSError **)error {
    NSString *directory = [self.socketPath stringByDeletingLastPathComponent];
    if (!EnsurePrivateDirectory(directory, error)) return NO;
    if (self.socketPath.fileSystemRepresentation == NULL || strlen(self.socketPath.fileSystemRepresentation) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        if (error) *error = SocketError(ENAMETOOLONG, @"Unix socket path is too long");
        return NO;
    }

    NSString *lockPath = [self.socketPath stringByAppendingString:@".lock"];
    int lockFD = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (lockFD < 0) {
        if (error) *error = SocketError(errno, @"Unable to open daemon lock file");
        return NO;
    }
    struct stat lockInfo;
    if (fstat(lockFD, &lockInfo) != 0 || !S_ISREG(lockInfo.st_mode) || lockInfo.st_uid != getuid() || flock(lockFD, LOCK_EX | LOCK_NB) != 0) {
        int code = errno ?: EBUSY;
        close(lockFD);
        if (error) *error = SocketError(code, @"Another daemon is running or the lock file is unsafe");
        return NO;
    }
    if (fchmod(lockFD, 0600) != 0) {
        int code = errno;
        close(lockFD);
        if (error) *error = SocketError(code, @"Unable to set daemon lock file permissions to 0600");
        return NO;
    }

    struct stat existing;
    if (lstat(self.socketPath.fileSystemRepresentation, &existing) == 0) {
        if (!S_ISSOCK(existing.st_mode) || existing.st_uid != getuid() || unlink(self.socketPath.fileSystemRepresentation) != 0) {
            close(lockFD);
            if (error) *error = SocketError(errno ?: EPERM, @"Refusing to replace a non-owned or non-socket path");
            return NO;
        }
    } else if (errno != ENOENT) {
        close(lockFD);
        if (error) *error = SocketError(errno, @"Unable to inspect socket path");
        return NO;
    }

    int serverFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (serverFD < 0) {
        close(lockFD);
        if (error) *error = SocketError(errno, @"Unable to create Unix domain socket");
        return NO;
    }
    int yes = 1;
    setsockopt(serverFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct sockaddr_un address = {};
    address.sun_len = sizeof(address);
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, self.socketPath.fileSystemRepresentation, sizeof(address.sun_path));
    mode_t oldMask = umask(0077);
    int bindResult = bind(serverFD, (struct sockaddr *)&address, sizeof(address));
    umask(oldMask);
    if (bindResult != 0) {
        int code = errno;
        close(serverFD);
        close(lockFD);
        if (error) *error = SocketError(code, [NSString stringWithFormat:@"Unable to bind Unix domain socket: %s", strerror(code)]);
        return NO;
    }
    struct stat socketIdentity;
    BOOL hasSocketIdentity = lstat(self.socketPath.fileSystemRepresentation, &socketIdentity) == 0 &&
        S_ISSOCK(socketIdentity.st_mode) && socketIdentity.st_uid == getuid();
    if (!hasSocketIdentity || chmod(self.socketPath.fileSystemRepresentation, 0600) != 0 || listen(serverFD, 1) != 0) {
        int code = errno ?: EIO;
        close(serverFD);
        struct stat failedSocket;
        if (hasSocketIdentity && lstat(self.socketPath.fileSystemRepresentation, &failedSocket) == 0 &&
            S_ISSOCK(failedSocket.st_mode) && failedSocket.st_dev == socketIdentity.st_dev &&
            failedSocket.st_ino == socketIdentity.st_ino && failedSocket.st_uid == getuid()) {
            unlink(self.socketPath.fileSystemRepresentation);
        }
        close(lockFD);
        if (error) *error = SocketError(code, [NSString stringWithFormat:@"Unable to secure/listen on Unix domain socket: %s", strerror(code)]);
        return NO;
    }

    int clientFD;
    do { clientFD = accept(serverFD, NULL, NULL); } while (clientFD < 0 && errno == EINTR);
    if (clientFD < 0) {
        if (error) *error = SocketError(errno, @"Unable to accept plugin connection");
        close(serverFD);
        struct stat finalSocket;
        if (hasSocketIdentity && lstat(self.socketPath.fileSystemRepresentation, &finalSocket) == 0 &&
            S_ISSOCK(finalSocket.st_mode) && finalSocket.st_dev == socketIdentity.st_dev &&
            finalSocket.st_ino == socketIdentity.st_ino && finalSocket.st_uid == getuid()) {
            unlink(self.socketPath.fileSystemRepresentation);
        }
        close(lockFD);
        return NO;
    }
    setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    [self serveClient:clientFD];
    shutdown(clientFD, SHUT_RDWR);
    close(clientFD);

    // Stop listening and remove the socket file immediately after the client
    // disconnects, BEFORE the pending-restore retry loop below. A daemon that
    // is still retrying DDC restorations keeps holding the flock; if its
    // (zombie) listening socket stayed bound, the next session's watcher
    // would connect to it, send HELLO, and block forever on a reply that
    // never comes — leaving that entire IINA session without mode switching.
    close(serverFD);
    struct stat disconnectedSocket;
    if (hasSocketIdentity && lstat(self.socketPath.fileSystemRepresentation, &disconnectedSocket) == 0 &&
        S_ISSOCK(disconnectedSocket.st_mode) && disconnectedSocket.st_dev == socketIdentity.st_dev &&
        disconnectedSocket.st_ino == socketIdentity.st_ino && disconnectedSocket.st_uid == getuid()) {
        unlink(self.socketPath.fileSystemRepresentation);
    }

    [self.stateManager releaseAll];
    NSTimeInterval interval = self.initialRetryInterval;
    // Bound the retry window: a display that stays unreachable would
    // otherwise keep the daemon (and its flock) alive forever, blocking every
    // future session from starting a daemon. Ten minutes is long enough for
    // display sleep/wake cycles while still recovering eventually.
    const time_t retryGiveUpAt = time(NULL) + 600;
    while (YES) {
        NSArray *managedDisplays = [self.stateManager statusDictionary][@"managedDisplays"];
        if (managedDisplays.count == 0) break;
        if (time(NULL) >= retryGiveUpAt) {
            // Give up with the restoration still pending; the display can be
            // reset manually from its OSD. Exiting releases the lock so a new
            // daemon can serve the next session.
            break;
        }
        usleep((useconds_t)(interval * 1000000.0));
        [self.stateManager retryPendingRestorations];
        interval = MIN(interval * 2.0, self.maximumRetryInterval);
    }

    close(lockFD);
    return YES;
}
@end

static BOOL ReadLine(FILE *stream, NSMutableData *line) {
    [line setLength:0];
    int character;
    while ((character = fgetc(stream)) != EOF) {
        uint8_t byte = (uint8_t)character;
        [line appendBytes:&byte length:1];
        if (byte == '\n') return YES;
        if (line.length > kMaximumMessageLength) return NO;
    }
    return line.length > 0;
}

BOOL RunDisplaySocketClient(NSString *socketPath, FILE *input, FILE *output, NSError **error) {
    if (strlen(socketPath.fileSystemRepresentation) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        if (error) *error = SocketError(ENAMETOOLONG, @"Unix socket path is too long");
        return NO;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = SocketError(errno, @"Unable to create client socket");
        return NO;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct sockaddr_un address = {};
    address.sun_len = sizeof(address);
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, socketPath.fileSystemRepresentation, sizeof(address.sun_path));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        int code = errno;
        close(fd);
        if (error) *error = SocketError(code, @"Unable to connect to display daemon");
        return NO;
    }

    NSDictionary *hello = @{@"type": @"HELLO", @"requestId": @1, @"client": @"display-helper-cli", @"version": @"1.0"};
    if (!WriteJSONLine(fd, hello)) {
        close(fd);
        if (error) *error = SocketError(EIO, @"Unable to send HELLO");
        return NO;
    }
    NSMutableData *buffer = [NSMutableData data];
    uint8_t chunk[4096];
    ssize_t received = recv(fd, chunk, sizeof(chunk), 0);
    if (received <= 0) {
        close(fd);
        if (error) *error = SocketError(EIO, @"Daemon closed before HELLO_ACK");
        return NO;
    }
    [buffer appendBytes:chunk length:(NSUInteger)received];
    const uint8_t *newline = memchr(buffer.bytes, '\n', buffer.length);
    if (!newline) {
        close(fd);
        if (error) *error = SocketError(EPROTO, @"Invalid HELLO_ACK line");
        return NO;
    }
    fwrite(buffer.bytes, 1, (size_t)(newline - (const uint8_t *)buffer.bytes + 1), output);
    fflush(output);

    NSMutableData *line = [NSMutableData data];
    while (ReadLine(input, line)) {
        if (((const uint8_t *)line.bytes)[line.length - 1] != '\n') {
            const uint8_t newlineByte = '\n';
            [line appendBytes:&newlineByte length:1];
        }
        NSError *messageError = nil;
        id inputMessage = [NSJSONSerialization JSONObjectWithData:line options:NSJSONReadingFragmentsAllowed error:&messageError];
        BOOL isQuit = [inputMessage isKindOfClass:NSDictionary.class] && [inputMessage[@"type"] isEqual:@"QUIT"];
        if (!WriteAll(fd, line.bytes, line.length)) break;
        NSMutableData *response = [NSMutableData data];
        BOOL gotLine = NO;
        while (!gotLine) {
            received = recv(fd, chunk, sizeof(chunk), 0);
            if (received <= 0) break;
            [response appendBytes:chunk length:(NSUInteger)received];
            newline = memchr(response.bytes, '\n', response.length);
            gotLine = newline != NULL;
            if (response.length > kMaximumMessageLength && !gotLine) break;
        }
        if (!gotLine) break;
        fwrite(response.bytes, 1, (size_t)(newline - (const uint8_t *)response.bytes + 1), output);
        fflush(output);
        if (isQuit) break;
    }
    shutdown(fd, SHUT_RDWR);
    close(fd);
    return YES;
}

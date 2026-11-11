#import <Foundation/Foundation.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>
#import "DisplayDiscovery.h"
#import "DisplayProfile.h"
#import "DDC/DDCBackend.h"
#import "Daemon/DisplayStateManager.h"
#import "Daemon/DisplaySocketServer.h"
#import "Daemon/DisplayWatcher.h"

static BOOL ParseUnsigned(NSString *text, unsigned long long max, unsigned long long *value) {
    const char *input = text.UTF8String;
    if (!input || !input[0] || input[0] == '-') return NO;
    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(input, &end, 0);
    if (errno != 0 || end == input || *end != '\0' || parsed > max) return NO;
    *value = parsed;
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *command = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"help";
        if ([command isEqualToString:@"list"]) {
            NSError *error = nil;
            NSArray<DisplayInfo *> *displays = DiscoverDisplays(&error);
            if (error) {
                fprintf(stderr, "display discovery failed: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            NSMutableArray *rows = [NSMutableArray arrayWithCapacity:displays.count];
            for (DisplayInfo *display in displays) {
                NSMutableDictionary *row = [[display JSONDictionary] mutableCopy];
                if (display.identity.length == 0) row[@"identityAvailable"] = @NO;
                else row[@"identityAvailable"] = @YES;
                [rows addObject:row];
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:&error];
            if (!json) {
                fprintf(stderr, "JSON serialization failed: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
            return 0;
        }
        if ([command isEqualToString:@"profiles"]) {
            NSError *error = DisplayProfileConfigurationError();
            if (error) {
                fprintf(stderr, "profile configuration failed: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            NSMutableArray *rows = [NSMutableArray array];
            for (DisplayProfile *profile in ConfiguredDisplayProfiles()) {
                [rows addObject:@{
                    @"model": profile.model,
                    @"vendorID": @(profile.vendorID),
                    @"productID": @(profile.productID),
                    @"featureCode": @(profile.featureCode),
                    @"movieValue": @(profile.movieValue),
                    @"verified": @(profile.isVerified)
                }];
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:&error];
            if (!json) {
                fprintf(stderr, "profile JSON serialization failed: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
            return 0;
        }
        if ([command isEqualToString:@"daemon"]) {
            NSString *socketPath = DefaultDisplaySocketPath();
            if (argc == 4 && strcmp(argv[2], "--socket") == 0) {
                socketPath = [NSString stringWithUTF8String:argv[3]];
            } else if (argc != 2) {
                fprintf(stderr, "Usage: display-helper daemon [--socket <path>]\n");
                return 2;
            }
            DisplayStateManager *manager = [[DisplayStateManager alloc] initWithBackend:[DDCDisplayStateBackend new]];
            DisplaySocketServer *server = [[DisplaySocketServer alloc] initWithStateManager:manager socketPath:socketPath];
            NSError *error = nil;
            if (![server runWithError:&error]) {
                fprintf(stderr, "daemon failed: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            return 0;
        }
        if ([command isEqualToString:@"client"] && (argc == 2 || argc == 3)) {
            NSString *socketPath = argc == 3 ? [NSString stringWithUTF8String:argv[2]] : DefaultDisplaySocketPath();
            NSError *error = nil;
            if (!RunDisplaySocketClient(socketPath, stdin, stdout, &error)) {
                fprintf(stderr, "client failed: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            return 0;
        }
        if ([command isEqualToString:@"probe"] && argc == 2) {
            NSDictionary *diagnosis = ResolveIINAWindowTarget();
            NSError *error = nil;
            NSData *json = [NSJSONSerialization dataWithJSONObject:diagnosis
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:&error];
            if (!json) {
                fprintf(stderr, "probe serialization failed: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
            return 0;
        }
        if ([command isEqualToString:@"watch"] && argc == 4) {
            char *end = NULL;
            unsigned long port = strtoul(argv[2], &end, 10);
            if (!end || *end || port == 0 || port > UINT16_MAX) {
                fprintf(stderr, "watch requires a valid WebSocket port and token\n");
                return 2;
            }
            NSError *error = nil;
            NSString *heartbeatToken = [NSString stringWithUTF8String:argv[3]];
            if (!RunDisplayWatcher([NSString stringWithUTF8String:argv[0]], DefaultDisplaySocketPath(), (uint16_t)port, heartbeatToken, &error)) {
                fprintf(stderr, "watcher failed: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            return 0;
        }
        if ([command isEqualToString:@"get"] && argc == 4) {
            unsigned long long feature = 0;
            if (!ParseUnsigned([NSString stringWithUTF8String:argv[3]], UINT8_MAX, &feature)) {
                fprintf(stderr, "feature must be an 8-bit decimal or 0x-prefixed value\n");
                return 2;
            }
            NSError *error = nil;
            DDCVCPValue value = {};
            if (!DDCReadVCP([NSString stringWithUTF8String:argv[2]], (uint8_t)feature, &value, &error)) {
                fprintf(stderr, "DDC Get failed: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            printf("{\"success\":true,\"feature\":%llu,\"currentValue\":%u,\"maximumValue\":%u,\"type\":%u}\n",
                   feature, value.currentValue, value.maximumValue, value.type);
            return 0;
        }
        if ([command isEqualToString:@"set"] && argc == 5) {
            unsigned long long feature = 0, value = 0;
            if (!ParseUnsigned([NSString stringWithUTF8String:argv[3]], UINT8_MAX, &feature) ||
                !ParseUnsigned([NSString stringWithUTF8String:argv[4]], UINT16_MAX, &value)) {
                fprintf(stderr, "feature must be 8-bit and value must be 16-bit (decimal or 0x-prefixed)\n");
                return 2;
            }
            NSError *error = nil;
            if (!DDCWriteVCP([NSString stringWithUTF8String:argv[2]], (uint8_t)feature, (uint16_t)value, &error)) {
                fprintf(stderr, "DDC Set failed: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            printf("{\"success\":true,\"identity\":\"%s\",\"feature\":%llu,\"currentValue\":%llu}\n",
                   argv[2], feature, value);
            return 0;
        }
        fprintf(stderr, "Usage:\n  display-helper list\n  display-helper profiles\n  display-helper probe\n  display-helper get <identity> <feature>\n  display-helper set <identity> <feature> <value>\n  display-helper daemon [--socket <path>]\n  display-helper client [<socket-path>]\n");
        return 2;
    }
}

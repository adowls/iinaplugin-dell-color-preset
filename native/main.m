#import <Foundation/Foundation.h>
#import "DisplayDiscovery.h"

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
        fprintf(stderr, "Usage: display-helper list\n");
        return 2;
    }
}

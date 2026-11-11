#import <Foundation/Foundation.h>
#import <stdint.h>

BOOL RunDisplayWatcher(NSString *helperPath, NSString *socketPath, uint16_t heartbeatPort, NSString *heartbeatToken, NSError **error);

// Resolves the display identity hosting IINA's player window and returns a
// JSON-serializable diagnosis dictionary. Used by `display-helper probe`.
NSDictionary<NSString *, id> *ResolveIINAWindowTarget(void);

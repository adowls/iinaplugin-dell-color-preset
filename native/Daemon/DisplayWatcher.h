#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <stdint.h>

BOOL RunDisplayWatcher(NSString *helperPath, NSString *socketPath, uint16_t heartbeatPort, NSString *heartbeatToken, NSError **error);

// Resolves the display identity hosting IINA's player window and returns a
// JSON-serializable diagnosis dictionary. Used by `display-helper probe`.
// holdTarget: YES when the caller currently holds a managed target (the
// watcher before releasing, the black-out helper) and should keep tracking
// an off-screen window instead of restarting from the best visible one.
NSDictionary<NSString *, id> *ResolveIINAWindowTarget(BOOL holdTarget);

// Diagnostic seeding for `display-helper probe <windowID> <displayID>`:
// simulates a watcher whose tracked window latched onto the given (typically
// hidden auxiliary) window after it was last visible on the given display.
void SeedTrackedMainWindow(NSNumber *windowID, CGDirectDisplayID displayID);

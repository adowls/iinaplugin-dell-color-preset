#import <Foundation/Foundation.h>

// Runs a resident helper that covers every screen except the one hosting
// IINA's player window with a borderless black window. The plugin controls it
// through `statePath` ("1" = enabled, anything else = stop) and `pidPath`.
BOOL RunDisplayBlackout(NSString *statePath, NSString *pidPath);

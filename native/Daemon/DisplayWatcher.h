#import <Foundation/Foundation.h>
#import <stdint.h>

BOOL RunDisplayWatcher(NSString *helperPath, NSString *socketPath, uint16_t heartbeatPort, NSString *heartbeatToken, NSError **error);

#import <Foundation/Foundation.h>
#import "DisplayStateManager.h"

NS_ASSUME_NONNULL_BEGIN

NSString *DefaultDisplaySocketPath(void);

@interface DisplaySocketServer : NSObject
- (instancetype)initWithStateManager:(DisplayStateManager *)stateManager
                          socketPath:(NSString *)socketPath;
- (instancetype)initWithStateManager:(DisplayStateManager *)stateManager
                          socketPath:(NSString *)socketPath
               initialRetryInterval:(NSTimeInterval)initialRetryInterval
                   maximumRetryInterval:(NSTimeInterval)maximumRetryInterval;
- (BOOL)runWithError:(NSError * _Nullable * _Nullable)error;
@end

BOOL RunDisplaySocketClient(NSString *socketPath, FILE *input, FILE *output, NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END

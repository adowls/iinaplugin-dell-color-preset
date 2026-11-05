#import <Foundation/Foundation.h>
#import "../DDC/DDCBackend.h"
#import "../DisplayProfile.h"

NS_ASSUME_NONNULL_BEGIN

@protocol DisplayStateBackend <NSObject>
- (nullable DisplayProfile *)profileForIdentity:(NSString *)identity error:(NSError * _Nullable * _Nullable)error;
- (BOOL)readFeature:(uint8_t)featureCode identity:(NSString *)identity
              value:(DDCVCPValue *)value error:(NSError * _Nullable * _Nullable)error;
- (BOOL)writeFeature:(uint8_t)featureCode identity:(NSString *)identity
               value:(uint16_t)value error:(NSError * _Nullable * _Nullable)error;
@end

@interface DDCDisplayStateBackend : NSObject <DisplayStateBackend>
@end

@interface DisplayStateManager : NSObject
@property(nonatomic, copy, readonly, nullable) NSString *targetIdentity;
@property(nonatomic, copy, readonly, nullable) NSString *lastError;
- (instancetype)initWithBackend:(id<DisplayStateBackend>)backend;
- (BOOL)setTargetIdentity:(nullable NSString *)identity error:(NSError * _Nullable * _Nullable)error;
- (BOOL)retryPendingRestorations;
- (BOOL)releaseAll;
- (NSDictionary<NSString *, id> *)statusDictionary;
@end

NS_ASSUME_NONNULL_END

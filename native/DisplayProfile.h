#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DisplayProfile : NSObject
@property(nonatomic, copy) NSString *model;
@property(nonatomic, assign) uint32_t vendorID;
@property(nonatomic, assign) uint32_t productID;
@property(nonatomic, assign) uint8_t featureCode;
@property(nonatomic, assign) uint16_t movieValue;
@property(nonatomic, assign, getter=isVerified) BOOL verified;
@end

DisplayProfile * _Nullable ProfileForDisplay(uint32_t vendorID, uint32_t productID, NSString *model);
NSArray<DisplayProfile *> * _Nullable LoadDisplayProfiles(NSData *data,
                                                           NSError * _Nullable * _Nullable error);
DisplayProfile * _Nullable ProfileForDisplayInProfiles(NSArray<DisplayProfile *> *profiles,
                                                        uint32_t vendorID,
                                                        uint32_t productID,
                                                        NSString *model);
NSArray<DisplayProfile *> *ConfiguredDisplayProfiles(void);
NSError * _Nullable DisplayProfileConfigurationError(void);

NS_ASSUME_NONNULL_END

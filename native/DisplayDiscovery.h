#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface DisplayInfo : NSObject
@property(nonatomic, copy) NSString *identity;
@property(nonatomic, copy, nullable) NSString *systemUUID;
@property(nonatomic, copy, nullable) NSString *edidUUID;
@property(nonatomic, copy, nullable) NSString *ioLocation;
@property(nonatomic, copy) NSString *model;
@property(nonatomic, copy) NSString *manufacturer;
@property(nonatomic, copy, nullable) NSString *alphanumericSerial;
@property(nonatomic, assign) uint32_t vendorID;
@property(nonatomic, assign) uint32_t productID;
@property(nonatomic, assign) uint32_t serialNumber;
@property(nonatomic, assign) CGDirectDisplayID displayID;
@property(nonatomic, assign) uint64_t ioRegistryID;
- (NSDictionary<NSString *, id> *)JSONDictionary;
@end

NSArray<DisplayInfo *> *DiscoverDisplays(NSError **error);
NSString * _Nullable StableDisplayIdentity(uint32_t vendorID, uint32_t productID,
                                            uint32_t serialNumber,
                                            NSString * _Nullable alphanumericSerial,
                                            NSString * _Nullable edidUUID);
NSString *DisplayManufacturerForVendorID(uint32_t vendorID);

NS_ASSUME_NONNULL_END

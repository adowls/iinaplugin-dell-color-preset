#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface DisplayInfo : NSObject
@property(nonatomic, copy) NSString *identity;
@property(nonatomic, copy) NSString *model;
@property(nonatomic, copy) NSString *manufacturer;
@property(nonatomic, copy, nullable) NSString *alphanumericSerial;
@property(nonatomic, assign) uint32_t vendorID;
@property(nonatomic, assign) uint32_t productID;
@property(nonatomic, assign) uint32_t serialNumber;
@property(nonatomic, assign) CGDirectDisplayID displayID;
- (NSDictionary<NSString *, id> *)JSONDictionary;
@end

NSArray<DisplayInfo *> *DiscoverDisplays(NSError **error);

NS_ASSUME_NONNULL_END

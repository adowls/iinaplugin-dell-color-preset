#import "DisplayDiscovery.h"
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <IOKit/IOKitLib.h>

@implementation DisplayInfo
- (NSDictionary<NSString *, id> *)JSONDictionary {
    NSMutableDictionary *result = [@{
        @"identity": self.identity,
        @"model": self.model,
        @"manufacturer": self.manufacturer,
        @"vendorID": @(self.vendorID),
        @"productID": @(self.productID),
        @"serialNumber": @(self.serialNumber),
        @"displayID": @(self.displayID)
    } mutableCopy];
    if (self.alphanumericSerial.length) result[@"alphanumericSerial"] = self.alphanumericSerial;
    return result;
}
@end

static NSString *StringFromDisplayInfo(NSDictionary *info, NSString *key) {
    id value = info[key];
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSData.class]) {
        return [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
    }
    return nil;
}

static NSString *StableIdentity(uint32_t vendor, uint32_t product, uint32_t serial,
                                NSString *alphaSerial, NSDictionary *info) {
    // IODisplayEDIDUUIDKey is preferred when the system supplies it. Serial-based
    // fallback is deliberately scoped by vendor/product and never uses Display ID.
    NSString *edidUUID = StringFromDisplayInfo(info, @"IODisplayEDIDUUID");
    if (edidUUID.length) return edidUUID.uppercaseString;
    NSString *serialPart = alphaSerial.length ? alphaSerial : (serial ? [NSString stringWithFormat:@"%08X", serial] : nil);
    if (!serialPart.length) return nil;
    return [NSString stringWithFormat:@"%04X-%04X-%@", vendor, product, serialPart.uppercaseString];
}

NSArray<DisplayInfo *> *DiscoverDisplays(NSError **error) {
    uint32_t count = 0;
    CGError cgError = CGGetOnlineDisplayList(0, NULL, &count);
    if (cgError != kCGErrorSuccess) {
        if (error) *error = [NSError errorWithDomain:@"DisplayDiscovery" code:cgError
            userInfo:@{NSLocalizedDescriptionKey: @"CGGetOnlineDisplayList failed"}];
        return @[];
    }
    NSMutableArray<DisplayInfo *> *displays = [NSMutableArray arrayWithCapacity:count];
    while (YES) {
        NSMutableData *buffer = [NSMutableData dataWithLength:sizeof(CGDirectDisplayID) * count];
        uint32_t actual = 0;
        cgError = CGGetOnlineDisplayList(count, buffer.mutableBytes, &actual);
        if (cgError == kCGErrorSuccess && actual <= count) {
            CGDirectDisplayID *ids = buffer.mutableBytes;
            for (uint32_t index = 0; index < actual; index++) {
                CGDirectDisplayID displayID = ids[index];
                io_service_t service = CGDisplayIOServicePort(displayID);
                if (service == MACH_PORT_NULL) continue;
                NSDictionary *info = CFBridgingRelease(IODisplayCreateInfoDictionary(service, kIODisplayOnlyPreferredName));
                if (!info) continue;
                NSDictionary *names = info[@"DisplayProductName"];
                NSString *model = names.allValues.firstObject ?: @"Unknown display";
                NSString *manufacturer = StringFromDisplayInfo(info, @"DisplayVendorName") ?: @"";
                uint32_t vendor = [info[@"DisplayVendorID"] unsignedIntValue];
                uint32_t product = [info[@"DisplayProductID"] unsignedIntValue];
                uint32_t serial = [info[@"DisplaySerialNumber"] unsignedIntValue];
                NSString *alpha = StringFromDisplayInfo(info, @"DisplaySerialNumberString");
                NSString *identity = StableIdentity(vendor, product, serial, alpha, info);
                DisplayInfo *item = [DisplayInfo new];
                item.identity = identity ?: @"";
                item.model = model;
                item.manufacturer = manufacturer;
                item.alphanumericSerial = alpha;
                item.vendorID = vendor;
                item.productID = product;
                item.serialNumber = serial;
                item.displayID = displayID;
                [displays addObject:item];
            }
            break;
        }
        if (cgError != kCGErrorSuccess || actual <= count) {
            if (error) *error = [NSError errorWithDomain:@"DisplayDiscovery" code:cgError
                userInfo:@{NSLocalizedDescriptionKey: @"Display list changed during enumeration"}];
            return @[];
        }
        count = actual;
    }
    return displays;
}

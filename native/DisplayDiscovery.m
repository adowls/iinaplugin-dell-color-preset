#import "DisplayDiscovery.h"
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>

@implementation DisplayInfo
- (NSDictionary<NSString *, id> *)JSONDictionary {
    NSMutableDictionary *result = [@{
        @"identity": self.identity,
        @"systemUUID": self.systemUUID ?: NSNull.null,
        @"edidUUID": self.edidUUID ?: NSNull.null,
        @"ioLocation": self.ioLocation ?: NSNull.null,
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

NSString *DisplayManufacturerForVendorID(uint32_t vendorID) {
    uint32_t high = (vendorID >> 10) & 0x1F;
    uint32_t middle = (vendorID >> 5) & 0x1F;
    uint32_t low = vendorID & 0x1F;
    if (high < 1 || high > 26 || middle < 1 || middle > 26 || low < 1 || low > 26) return @"";
    return [NSString stringWithFormat:@"%C%C%C", (unichar)('A' + high - 1),
            (unichar)('A' + middle - 1), (unichar)('A' + low - 1)];
}

typedef CFDictionaryRef (*DisplayCreateInfoDictionaryFunction)(CGDirectDisplayID);

static NSDictionary *CoreDisplayInfo(CGDirectDisplayID displayID) {
    static void *frameworkHandle = NULL;
    static DisplayCreateInfoDictionaryFunction createInfo = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        frameworkHandle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL);
        if (frameworkHandle) createInfo = (DisplayCreateInfoDictionaryFunction)dlsym(frameworkHandle, "CoreDisplay_DisplayCreateInfoDictionary");
    });
    if (!createInfo) return nil;
    CFDictionaryRef dictionary = createInfo(displayID);
    return dictionary ? CFBridgingRelease(dictionary) : nil;
}

static DisplayInfo *DisplayInfoFromDictionary(NSDictionary *info, CGDirectDisplayID displayID,
                                               uint64_t registryID, NSDictionary *coreInfo) {
    NSDictionary *names = info[@"DisplayProductName"];
    NSString *model = names.allValues.firstObject;
    if (![model isKindOfClass:NSString.class]) model = @"Unknown display";
    NSString *manufacturer = StringFromDisplayInfo(info, @"DisplayVendorName");
    uint32_t vendor = [info[@"DisplayVendorID"] unsignedIntValue];
    uint32_t product = [info[@"DisplayProductID"] unsignedIntValue];
    uint32_t serial = [info[@"DisplaySerialNumber"] unsignedIntValue];
    NSString *alpha = StringFromDisplayInfo(info, @"DisplaySerialNumberString");
    NSString *edidUUID = StringFromDisplayInfo(coreInfo, @"EDID UUID");
    if (!edidUUID.length) edidUUID = StringFromDisplayInfo(coreInfo, @"IODisplayEDIDUUID");
    NSString *systemUUID = StringFromDisplayInfo(coreInfo, @"kCGDisplayUUID");
    NSString *ioLocation = StringFromDisplayInfo(coreInfo, @"IODisplayLocation");
    if (!manufacturer.length) manufacturer = DisplayManufacturerForVendorID(vendor);
    DisplayInfo *item = [DisplayInfo new];
    item.identity = StableDisplayIdentity(vendor, product, serial, alpha, edidUUID) ?: @"";
    item.edidUUID = edidUUID;
    item.ioLocation = ioLocation;
    item.systemUUID = systemUUID;
    item.model = model;
    item.manufacturer = manufacturer;
    item.alphanumericSerial = alpha;
    item.vendorID = vendor;
    item.productID = product;
    item.serialNumber = serial;
    item.displayID = displayID;
    item.ioRegistryID = registryID;
    return item;
}

static NSString *DisplayDeduplicationKey(DisplayInfo *display) {
    if (display.identity.length) return display.identity;
    return [NSString stringWithFormat:@"unidentified-%llu", display.ioRegistryID];
}

NSString *StableDisplayIdentity(uint32_t vendor, uint32_t product, uint32_t serial,
                                NSString *alphaSerial, NSString *edidUUID) {
    // EDID UUIDs can be duplicated by a batch of identical displays. Always
    // qualify the EDID UUID with the serial before treating it as an identity.
    NSString *serialPart = alphaSerial.length ? alphaSerial : (serial ? [NSString stringWithFormat:@"%08X", serial] : nil);
    if (!serialPart.length) return nil;
    if (edidUUID.length) {
        return [NSString stringWithFormat:@"%@|%04X-%04X-%@", edidUUID.uppercaseString, vendor, product, serialPart.uppercaseString];
    }
    return [NSString stringWithFormat:@"%04X-%04X-%@", vendor, product, serialPart.uppercaseString];
}

NSArray<DisplayInfo *> *DiscoverDisplays(NSError **error) {
    NSMutableDictionary<NSString *, DisplayInfo *> *found = [NSMutableDictionary dictionary];
    uint32_t capacity = 16;
    CGError cgError = kCGErrorSuccess;
    while (YES) {
        NSMutableData *buffer = [NSMutableData dataWithLength:sizeof(CGDirectDisplayID) * capacity];
        uint32_t actual = 0;
        cgError = CGGetOnlineDisplayList(capacity, buffer.mutableBytes, &actual);
        if (cgError == kCGErrorSuccess && actual <= capacity) {
            CGDirectDisplayID *ids = buffer.mutableBytes;
            for (uint32_t index = 0; index < actual; index++) {
                CGDirectDisplayID displayID = ids[index];
                NSDictionary *coreInfo = CoreDisplayInfo(displayID);
                io_service_t service = CGDisplayIOServicePort(displayID);
                NSDictionary *info = nil;
                uint64_t registryID = 0;
                if (service != MACH_PORT_NULL) {
                    info = CFBridgingRelease(IODisplayCreateInfoDictionary(service, kIODisplayOnlyPreferredName));
                    IORegistryEntryGetRegistryEntryID(service, &registryID);
                }
                // On Apple Silicon the legacy CG-to-IODisplay service bridge can
                // be absent. Use the same CoreDisplay dictionary path as m1ddc.
                if (!info) info = coreInfo;
                if (!info) continue;
                DisplayInfo *item = DisplayInfoFromDictionary(info, displayID, registryID, coreInfo);
                found[DisplayDeduplicationKey(item)] = item;
            }
            break;
        }
        if (cgError == kCGErrorRangeCheck) {
            capacity = MAX(capacity * 2, actual);
            continue;
        }
        if (cgError != kCGErrorSuccess) {
            break;
        }
        capacity = MAX(capacity * 2, actual);
    }

    // CoreGraphics can return no online displays when the helper is launched
    // outside the WindowServer session. Enumerate IODisplayConnect services as
    // a second source so attached panels remain discoverable in that case.
    CFMutableDictionaryRef matching = IOServiceMatching("IODisplayConnect");
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t ioResult = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (ioResult == KERN_SUCCESS) {
        io_service_t service;
        while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
            NSDictionary *info = CFBridgingRelease(IODisplayCreateInfoDictionary(service, kIODisplayOnlyPreferredName));
            if (info) {
                uint64_t registryID = 0;
                IORegistryEntryGetRegistryEntryID(service, &registryID);
                DisplayInfo *item = DisplayInfoFromDictionary(info, 0, registryID, nil);
                NSString *key = DisplayDeduplicationKey(item);
                DisplayInfo *existing = found[key];
                if (!existing || (existing.displayID == 0 && item.displayID != 0)) found[key] = item;
            }
            IOObjectRelease(service);
        }
        IOObjectRelease(iterator);
    } else if (found.count == 0 && error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ioResult
            userInfo:@{NSLocalizedDescriptionKey: @"Unable to enumerate IODisplayConnect services"}];
    }

    if (found.count == 0 && error && !*error) {
        *error = [NSError errorWithDomain:@"DisplayDiscovery" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"No displays were returned by CoreGraphics or IOKit"}];
    }

    return [[found allValues] sortedArrayUsingComparator:^NSComparisonResult(DisplayInfo *a, DisplayInfo *b) {
        NSComparisonResult modelOrder = [a.model localizedCaseInsensitiveCompare:b.model];
        return modelOrder == NSOrderedSame ? [a.identity compare:b.identity] : modelOrder;
    }];
}

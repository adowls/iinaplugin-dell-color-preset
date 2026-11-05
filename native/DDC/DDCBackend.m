#import "DDCBackend.h"
#import "../DisplayDiscovery.h"
#import "../DisplayProfile.h"
#import <IOKit/IOKitLib.h>
#import <mach/mach_error.h>
#import <dlfcn.h>
#import <string.h>
#import <unistd.h>

static NSString * const DDCErrorDomain = @"IINADellDDC";
enum { DDCErrorDiscovery = 1, DDCErrorIdentity, DDCErrorProfile, DDCErrorTransport,
       DDCErrorIO, DDCErrorProtocol, DDCErrorVerification };

typedef CFTypeRef IOAVServiceRef;
typedef IOAVServiceRef (*IOAVServiceCreateWithServiceFunction)(CFAllocatorRef, io_service_t);
typedef IOReturn (*IOAVServiceReadI2CFunction)(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
typedef IOReturn (*IOAVServiceWriteI2CFunction)(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);

typedef struct {
    void *framework;
    IOAVServiceCreateWithServiceFunction create;
    IOAVServiceReadI2CFunction read;
    IOAVServiceWriteI2CFunction write;
} DDCPrivateAPI;

typedef struct {
    IOAVServiceRef service;
    uint32_t chipAddress;
} DDCTransport;

static DDCPrivateAPI PrivateAPI(void) {
    static DDCPrivateAPI api;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        api.framework = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL);
        if (!api.framework) return;
        api.create = (IOAVServiceCreateWithServiceFunction)dlsym(api.framework, "IOAVServiceCreateWithService");
        api.read = (IOAVServiceReadI2CFunction)dlsym(api.framework, "IOAVServiceReadI2C");
        api.write = (IOAVServiceWriteI2CFunction)dlsym(api.framework, "IOAVServiceWriteI2C");
    });
    return api;
}

static NSError *DDCError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:DDCErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static uint8_t Checksum(uint8_t seed, const uint8_t *bytes, size_t length) {
    for (size_t i = 0; i < length; i++) seed ^= bytes[i];
    return seed;
}

NSData *DDCGetRequest(uint8_t featureCode) {
    uint8_t frame[4] = {0x82, 0x01, featureCode, 0};
    frame[3] = Checksum((uint8_t)(0x6E ^ 0x51), frame, 3);
    return [NSData dataWithBytes:frame length:sizeof(frame)];
}

NSData *DDCSetRequest(uint8_t featureCode, uint16_t value) {
    uint8_t frame[6] = {0x84, 0x03, featureCode, (uint8_t)(value >> 8), (uint8_t)value, 0};
    frame[5] = Checksum((uint8_t)(0x6E ^ 0x51), frame, 5);
    return [NSData dataWithBytes:frame length:sizeof(frame)];
}

BOOL DDCParseVCPReply(NSData *reply, uint8_t expectedFeature, DDCVCPValue *value, NSError **error) {
    const uint8_t *bytes = reply.bytes;
    if (reply.length < 11) {
        if (error) *error = DDCError(DDCErrorProtocol, @"VCP reply is shorter than 11 bytes");
        return NO;
    }
    if (bytes[0] != 0x6E || bytes[1] != 0x88 || bytes[2] != 0x02) {
        if (error) *error = DDCError(DDCErrorProtocol,
            [NSString stringWithFormat:@"Unexpected DDC reply header/type: %02X %02X %02X", bytes[0], bytes[1], bytes[2]]);
        return NO;
    }
    if (bytes[3] != 0) {
        if (error) *error = DDCError(DDCErrorProtocol,
            [NSString stringWithFormat:@"Monitor returned DDC result code 0x%02X", bytes[3]]);
        return NO;
    }
    if (bytes[4] != expectedFeature) {
        if (error) *error = DDCError(DDCErrorProtocol,
            [NSString stringWithFormat:@"VCP feature mismatch: requested 0x%02X, received 0x%02X", expectedFeature, bytes[4]]);
        return NO;
    }
    if (bytes[5] > 1) {
        if (error) *error = DDCError(DDCErrorProtocol,
            [NSString stringWithFormat:@"Unsupported VCP value type 0x%02X", bytes[5]]);
        return NO;
    }
    if (Checksum(0x50, bytes, 10) != bytes[10]) {
        if (error) *error = DDCError(DDCErrorProtocol, @"VCP reply checksum mismatch");
        return NO;
    }
    if (value) {
        value->type = bytes[5];
        value->maximumValue = (uint16_t)(((uint16_t)bytes[6] << 8) | bytes[7]);
        value->currentValue = (uint16_t)(((uint16_t)bytes[8] << 8) | bytes[9]);
    }
    return YES;
}

static BOOL FindDisplay(NSString *identity, DisplayInfo **selected, NSError **error) {
    NSError *discoveryError = nil;
    NSArray<DisplayInfo *> *displays = DiscoverDisplays(&discoveryError);
    if (discoveryError) {
        if (error) *error = DDCError(DDCErrorDiscovery, discoveryError.localizedDescription);
        return NO;
    }
    DisplayInfo *match = nil;
    for (DisplayInfo *display in displays) {
        if (![display.identity isEqualToString:identity]) continue;
        if (match) {
            if (error) *error = DDCError(DDCErrorIdentity, @"Display identity is ambiguous; refusing DDC operation");
            return NO;
        }
        match = display;
    }
    if (!match) {
        if (error) *error = DDCError(DDCErrorIdentity, @"No online display matches the supplied stable identity");
        return NO;
    }
    if (!match.ioLocation.length) {
        if (error) *error = DDCError(DDCErrorTransport, @"Display has no IODisplayLocation; refusing to guess a DDC route");
        return NO;
    }
    *selected = match;
    return YES;
}

static BOOL IsMCDP29XXProxy(io_service_t proxy) {
    io_registry_entry_t parent = MACH_PORT_NULL;
    if (IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) != KERN_SUCCESS) return NO;
    CFTypeRef provider = IORegistryEntryCreateCFProperty(parent, CFSTR("EPICProviderClass"), kCFAllocatorDefault, 0);
    BOOL isMCDP = provider && CFGetTypeID(provider) == CFStringGetTypeID() &&
        CFStringCompare((CFStringRef)provider, CFSTR("AppleDCPMCDP29XX"), 0) == kCFCompareEqualTo;
    if (provider) CFRelease(provider);
    IOObjectRelease(parent);
    return isMCDP;
}

static DDCTransport DisplayTransport(DisplayInfo *display, NSError **error) {
    DDCTransport transport = {NULL, 0x37};
    DDCPrivateAPI api = PrivateAPI();
    if (!api.create || !api.read || !api.write) {
        if (error) *error = DDCError(DDCErrorTransport, @"CoreDisplay IOAVService APIs are unavailable on this macOS version");
        return transport;
    }
    io_service_t adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, (__bridge CFStringRef)display.ioLocation);
    if (adapter == MACH_PORT_NULL) {
        if (error) *error = DDCError(DDCErrorTransport, @"Could not resolve this display's IODisplayLocation in IORegistry");
        return transport;
    }
    uint64_t targetAdapterID = 0;
    kern_return_t result = IORegistryEntryGetRegistryEntryID(adapter, &targetAdapterID);
    IOObjectRelease(adapter);
    if (result != KERN_SUCCESS) {
        if (error) *error = DDCError(DDCErrorTransport, @"Could not read display adapter registry ID");
        return transport;
    }

    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    io_iterator_t iterator = IO_OBJECT_NULL;
    result = IORegistryEntryCreateIterator(root, kIOServicePlane, kIORegistryIterateRecursively, &iterator);
    IOObjectRelease(root);
    if (result != KERN_SUCCESS) {
        if (error) *error = DDCError(DDCErrorTransport, @"Could not iterate the IOService registry");
        return transport;
    }

    BOOL framebufferMatches = NO;
    io_service_t entry = IO_OBJECT_NULL;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        if (IOObjectConformsTo(entry, "IOMobileFramebuffer")) {
            uint64_t framebufferID = 0;
            framebufferMatches = IORegistryEntryGetRegistryEntryID(entry, &framebufferID) == KERN_SUCCESS &&
                framebufferID == targetAdapterID;
            IOObjectRelease(entry);
            continue;
        }
        io_name_t name = {};
        IORegistryEntryGetName(entry, name);
        if (!framebufferMatches || strcmp(name, "DCPAVServiceProxy") != 0) {
            IOObjectRelease(entry);
            continue;
        }
        CFTypeRef service = api.create(kCFAllocatorDefault, entry);
        CFTypeRef location = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, CFSTR("Location"),
                                                               kCFAllocatorDefault, kIORegistryIterateRecursively);
        BOOL external = location && CFGetTypeID(location) == CFStringGetTypeID() &&
            CFStringCompare((CFStringRef)location, CFSTR("External"), 0) == kCFCompareEqualTo;
        if (location) CFRelease(location);
        if (service && external) {
            transport.service = service;
            transport.chipAddress = IsMCDP29XXProxy(entry) ? 0xB7 : 0x37;
            IOObjectRelease(entry);
            break;
        }
        if (service) CFRelease(service);
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
    if (!transport.service && error) *error = DDCError(DDCErrorTransport, @"No external DCPAVServiceProxy found for this display");
    return transport;
}

static void ReleaseTransport(DDCTransport transport) {
    if (transport.service) CFRelease(transport.service);
}

static IOReturn WriteFrame(DDCTransport transport, NSData *frame) {
    DDCPrivateAPI api = PrivateAPI();
    IOReturn result = kIOReturnSuccess;
    // Several displays need the request written twice; this is the behavior used by m1ddc.
    for (int attempt = 0; attempt < 2; attempt++) {
        usleep(10000);
        result = api.write(transport.service, transport.chipAddress, 0x51,
                           (void *)frame.bytes, (uint32_t)frame.length);
        if (result != kIOReturnSuccess) return result;
    }
    return result;
}

static BOOL ReadWithTransport(DDCTransport transport, uint8_t featureCode,
                              DDCVCPValue *value, NSError **error) {
    DDCPrivateAPI api = PrivateAPI();
    NSError *lastError = nil;
    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        NSData *request = DDCGetRequest(featureCode);
        IOReturn result = WriteFrame(transport, request);
        if (result != kIOReturnSuccess) {
            lastError = DDCError(DDCErrorIO, [NSString stringWithFormat:@"DDC Get request failed: %s", mach_error_string(result)]);
            usleep(30000);
            continue;
        }
        usleep(transport.chipAddress == 0xB7 ? 50000 : 20000);
        uint8_t reply[12] = {0};
        result = api.read(transport.service, transport.chipAddress, 0x51, reply, sizeof(reply));
        if (result != kIOReturnSuccess) {
            lastError = DDCError(DDCErrorIO, [NSString stringWithFormat:@"DDC reply read failed: %s", mach_error_string(result)]);
            usleep(30000);
            continue;
        }
        if (DDCParseVCPReply([NSData dataWithBytes:reply length:sizeof(reply)], featureCode, value, &lastError)) return YES;
        usleep(30000);
    }
    if (error) *error = lastError ?: DDCError(DDCErrorIO, @"DDC Get failed after three attempts");
    return NO;
}

BOOL DDCReadVCP(NSString *identity, uint8_t featureCode, DDCVCPValue *value, NSError **error) {
    DisplayInfo *display = nil;
    if (!FindDisplay(identity, &display, error)) return NO;
    NSError *transportError = nil;
    DDCTransport transport = DisplayTransport(display, &transportError);
    if (!transport.service) {
        if (error) *error = transportError;
        return NO;
    }
    BOOL success = ReadWithTransport(transport, featureCode, value, error);
    ReleaseTransport(transport);
    return success;
}

BOOL DDCWriteVCP(NSString *identity, uint8_t featureCode, uint16_t value, NSError **error) {
    DisplayInfo *display = nil;
    if (!FindDisplay(identity, &display, error)) return NO;
    DisplayProfile *profile = ProfileForDisplay(display.vendorID, display.productID, display.model);
    if (featureCode == 0xDC && (!profile || profile.featureCode != featureCode)) {
        NSError *configurationError = DisplayProfileConfigurationError();
        NSString *reason = configurationError
            ? configurationError.localizedDescription
            : @"display does not match a verified profile";
        if (error) *error = DDCError(DDCErrorProfile,
            [NSString stringWithFormat:@"Color Preset writes are disabled: %@", reason]);
        return NO;
    }
    NSError *transportError = nil;
    DDCTransport transport = DisplayTransport(display, &transportError);
    if (!transport.service) {
        if (error) *error = transportError;
        return NO;
    }
    DDCVCPValue original = {};
    NSError *originalReadError = nil;
    if (!ReadWithTransport(transport, featureCode, &original, &originalReadError)) {
        if (error) *error = DDCError(DDCErrorVerification,
            [NSString stringWithFormat:@"Refusing to write without a readable original VCP value: %@", originalReadError.localizedDescription]);
        ReleaseTransport(transport);
        return NO;
    }
    if (value > original.maximumValue) {
        if (error) *error = DDCError(DDCErrorVerification,
            [NSString stringWithFormat:@"Refusing value %u above the feature maximum %u", value, original.maximumValue]);
        ReleaseTransport(transport);
        return NO;
    }
    if (original.currentValue == value) {
        ReleaseTransport(transport);
        return YES;
    }
    NSData *frame = DDCSetRequest(featureCode, value);
    IOReturn result = WriteFrame(transport, frame);
    if (result != kIOReturnSuccess) {
        NSError *writeError = DDCError(DDCErrorIO, [NSString stringWithFormat:@"DDC Set request failed: %s", mach_error_string(result)]);
        NSData *rollbackFrame = DDCSetRequest(featureCode, original.currentValue);
        BOOL rollbackWritten = WriteFrame(transport, rollbackFrame) == kIOReturnSuccess;
        usleep(50000);
        DDCVCPValue rollbackValue = {};
        BOOL rollbackVerified = rollbackWritten && ReadWithTransport(transport, featureCode, &rollbackValue, NULL) &&
            rollbackValue.currentValue == original.currentValue;
        if (error) *error = DDCError(DDCErrorIO, [NSString stringWithFormat:@"%@; rollback %@",
            writeError.localizedDescription, rollbackVerified ? @"verified" : @"could not be verified"]);
        ReleaseTransport(transport);
        return NO;
    }
    usleep(50000);
    DDCVCPValue verify = {};
    NSError *verifyError = nil;
    BOOL readOK = ReadWithTransport(transport, featureCode, &verify, &verifyError);
    if (!readOK || verify.currentValue != value) {
        NSString *reason = readOK
            ? [NSString stringWithFormat:@"DDC Set verification mismatch: requested %u, read back %u", value, verify.currentValue]
            : verifyError.localizedDescription;
        NSData *rollbackFrame = DDCSetRequest(featureCode, original.currentValue);
        BOOL rollbackWritten = WriteFrame(transport, rollbackFrame) == kIOReturnSuccess;
        usleep(50000);
        DDCVCPValue rollbackValue = {};
        BOOL rollbackVerified = rollbackWritten && ReadWithTransport(transport, featureCode, &rollbackValue, NULL) &&
            rollbackValue.currentValue == original.currentValue;
        if (error) *error = DDCError(DDCErrorVerification, [NSString stringWithFormat:@"%@; rollback %@",
            reason, rollbackVerified ? @"verified" : @"could not be verified"]);
        ReleaseTransport(transport);
        return NO;
    }
    ReleaseTransport(transport);
    return YES;
}

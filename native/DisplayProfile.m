#import "DisplayProfile.h"
#import <CoreFoundation/CoreFoundation.h>
#import <mach-o/dyld.h>
#import <limits.h>
#import <stdlib.h>

static NSArray<DisplayProfile *> *gConfiguredProfiles;
static NSError *gConfigurationError;
static dispatch_once_t gConfigurationOnce;

@implementation DisplayProfile
@end

static NSError *ProfileError(NSString *message) {
    return [NSError errorWithDomain:@"DisplayProfile" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL IsNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
}

NSArray<DisplayProfile *> *LoadDisplayProfiles(NSData *data, NSError **error) {
    NSError *jsonError = nil;
    id document = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![document isKindOfClass:NSDictionary.class]) {
        if (error) *error = jsonError ?: ProfileError(@"Profile document must be a JSON object");
        return nil;
    }
    id schemaVersion = document[@"schemaVersion"];
    if (!IsNumber(schemaVersion) || [schemaVersion unsignedIntegerValue] != 1) {
        if (error) *error = ProfileError(@"Unsupported or missing profile schemaVersion");
        return nil;
    }
    id entries = document[@"profiles"];
    if (![entries isKindOfClass:NSArray.class] || [entries count] == 0) {
        if (error) *error = ProfileError(@"Profile document must contain a non-empty profiles array");
        return nil;
    }

    NSMutableArray<DisplayProfile *> *profiles = [NSMutableArray arrayWithCapacity:[entries count]];
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    for (id entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class]) {
            if (error) *error = ProfileError(@"Every profile entry must be an object");
            return nil;
        }
        NSDictionary *fields = entry;
        id model = fields[@"model"];
        id vendor = fields[@"vendorID"];
        id product = fields[@"productID"];
        id feature = fields[@"featureCode"];
        id movie = fields[@"movieValue"];
        id verified = fields[@"verified"];
        if (![model isKindOfClass:NSString.class] || [model length] == 0 ||
            !IsNumber(vendor) || !IsNumber(product) || !IsNumber(feature) || !IsNumber(movie) ||
            ![verified isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)verified) != CFBooleanGetTypeID() ||
            [vendor unsignedLongLongValue] > UINT16_MAX || [product unsignedLongLongValue] > UINT16_MAX ||
            [feature unsignedLongLongValue] > UINT8_MAX || [movie unsignedLongLongValue] > UINT16_MAX) {
            if (error) *error = ProfileError(@"Profile entry has missing or invalid fields");
            return nil;
        }
        NSString *key = [NSString stringWithFormat:@"%04X:%04X:%@", [vendor unsignedIntValue],
                         [product unsignedIntValue], [model uppercaseString]];
        if ([keys containsObject:key]) {
            if (error) *error = ProfileError([NSString stringWithFormat:@"Duplicate profile key %@", key]);
            return nil;
        }
        [keys addObject:key];

        DisplayProfile *profile = [DisplayProfile new];
        profile.model = [model uppercaseString];
        profile.vendorID = [vendor unsignedIntValue];
        profile.productID = [product unsignedIntValue];
        profile.featureCode = [feature unsignedIntValue];
        profile.movieValue = [movie unsignedIntValue];
        profile.verified = [verified boolValue];
        [profiles addObject:profile];
    }
    return [profiles copy];
}

DisplayProfile *ProfileForDisplayInProfiles(NSArray<DisplayProfile *> *profiles,
                                             uint32_t vendorID,
                                             uint32_t productID,
                                             NSString *model) {
    NSCharacterSet *separator = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSArray<NSString *> *tokens = [[model uppercaseString] componentsSeparatedByCharactersInSet:separator];
    for (DisplayProfile *profile in profiles) {
        if (!profile.isVerified || profile.vendorID != vendorID || profile.productID != productID) continue;
        if ([tokens.lastObject isEqualToString:profile.model]) return profile;
    }
    return nil;
}

static NSString *ProfilePathForCurrentExecutable(void) {
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    if (size == 0) return nil;
    char *pathBuffer = calloc(size + 1, 1);
    if (!pathBuffer) return nil;
    if (_NSGetExecutablePath(pathBuffer, &size) != 0) {
        free(pathBuffer);
        return nil;
    }
    NSString *executable = [NSString stringWithUTF8String:pathBuffer];
    free(pathBuffer);
    return [[[executable stringByResolvingSymlinksInPath] stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"profiles.json"];
}

NSArray<DisplayProfile *> *ConfiguredDisplayProfiles(void) {
    dispatch_once(&gConfigurationOnce, ^{
        NSString *path = ProfilePathForCurrentExecutable();
        if (!path) {
            gConfigurationError = ProfileError(@"Could not resolve the helper path to load profiles.json");
            gConfiguredProfiles = @[];
            return;
        }
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) {
            gConfigurationError = ProfileError([NSString stringWithFormat:@"Could not read profile configuration at %@", path]);
            gConfiguredProfiles = @[];
            return;
        }
        NSError *profileError = nil;
        gConfiguredProfiles = LoadDisplayProfiles(data, &profileError);
        gConfigurationError = profileError;
        if (!gConfiguredProfiles) gConfiguredProfiles = @[];
    });
    return gConfiguredProfiles;
}

NSError *DisplayProfileConfigurationError(void) {
    (void)ConfiguredDisplayProfiles();
    return gConfigurationError;
}

DisplayProfile *ProfileForDisplay(uint32_t vendorID, uint32_t productID, NSString *model) {
    return ProfileForDisplayInProfiles(ConfiguredDisplayProfiles(), vendorID, productID, model);
}

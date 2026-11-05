#import "DisplayStateManager.h"
#import "../DisplayDiscovery.h"

@interface ManagedDisplayState : NSObject
@property(nonatomic, copy) NSString *identity;
@property(nonatomic, assign) uint16_t originalValue;
@property(nonatomic, assign) uint16_t movieValue;
@property(nonatomic, assign) uint8_t featureCode;
@property(nonatomic, assign) BOOL originallyMovie;
@property(nonatomic, assign) BOOL changedByPlugin;
@property(nonatomic, assign) BOOL restorePending;
@property(nonatomic, copy, nullable) NSString *lastError;
@end
@implementation ManagedDisplayState
@end

@implementation DDCDisplayStateBackend
- (DisplayProfile *)profileForIdentity:(NSString *)identity error:(NSError **)error {
    NSError *discoveryError = nil;
    NSArray<DisplayInfo *> *displays = DiscoverDisplays(&discoveryError);
    if (discoveryError) {
        if (error) *error = discoveryError;
        return nil;
    }
    DisplayInfo *match = nil;
    for (DisplayInfo *display in displays) {
        if (![display.identity isEqualToString:identity]) continue;
        if (match) {
            if (error) *error = [NSError errorWithDomain:@"DisplayStateManager" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"Display identity is ambiguous"}];
            return nil;
        }
        match = display;
    }
    if (!match) {
        if (error) *error = [NSError errorWithDomain:@"DisplayStateManager" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"Display is not currently online"}];
        return nil;
    }
    DisplayProfile *profile = ProfileForDisplay(match.vendorID, match.productID, match.model);
    if (!profile || !profile.isVerified) {
        if (error) *error = [NSError errorWithDomain:@"DisplayStateManager" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"Display has no verified automatic preset profile"}];
        return nil;
    }
    if (profile.featureCode != 0xDC) {
        if (error) *error = [NSError errorWithDomain:@"DisplayStateManager" code:7
            userInfo:@{NSLocalizedDescriptionKey: @"Verified profile does not describe Color Preset VCP 0xDC"}];
        return nil;
    }
    return profile;
}

- (BOOL)readFeature:(uint8_t)featureCode identity:(NSString *)identity value:(DDCVCPValue *)value error:(NSError **)error {
    return DDCReadVCP(identity, featureCode, value, error);
}

- (BOOL)writeFeature:(uint8_t)featureCode identity:(NSString *)identity value:(uint16_t)value error:(NSError **)error {
    return DDCWriteVCP(identity, featureCode, value, error);
}
@end

@interface DisplayStateManager ()
@property(nonatomic, strong) id<DisplayStateBackend> backend;
@property(nonatomic, strong) NSMutableDictionary<NSString *, ManagedDisplayState *> *states;
@property(nonatomic, strong) NSRecursiveLock *lock;
@property(nonatomic, copy, readwrite, nullable) NSString *targetIdentity;
@property(nonatomic, copy, readwrite, nullable) NSString *lastError;
@end

@implementation DisplayStateManager
- (instancetype)initWithBackend:(id<DisplayStateBackend>)backend {
    self = [super init];
    if (self) {
        _backend = backend;
        _states = [NSMutableDictionary dictionary];
        _lock = [NSRecursiveLock new];
    }
    return self;
}

- (BOOL)setTargetIdentity:(NSString *)identity error:(NSError **)error {
    [self.lock lock];
    @try {
        NSString *newIdentity = [identity copy];
        BOOL sameTarget = (self.targetIdentity == newIdentity) || [self.targetIdentity isEqualToString:newIdentity];
        self.targetIdentity = newIdentity;

        NSArray<NSString *> *knownIdentities = self.states.allKeys;
        for (NSString *knownIdentity in knownIdentities) {
            if ([knownIdentity isEqualToString:newIdentity]) continue;
            [self releaseIdentity:knownIdentity];
        }

        if (!newIdentity) return YES;
        ManagedDisplayState *existing = self.states[newIdentity];
        if (existing && !existing.restorePending) return YES;
        if (existing.restorePending) {
            [self restoreIdentity:newIdentity];
            if (self.states[newIdentity]) {
                if (error) *error = [NSError errorWithDomain:@"DisplayStateManager" code:4
                    userInfo:@{NSLocalizedDescriptionKey: @"Display restoration is still pending; refusing to reacquire it"}];
                return NO;
            }
        }
        BOOL acquired = [self acquireIdentity:newIdentity error:error];
        if (!acquired && !sameTarget && self.lastError.length == 0 && error && *error) {
            self.lastError = (*error).localizedDescription;
        }
        return acquired;
    } @finally {
        [self.lock unlock];
    }
}

- (BOOL)acquireIdentity:(NSString *)identity error:(NSError **)error {
    NSError *operationError = nil;
    DisplayProfile *profile = [self.backend profileForIdentity:identity error:&operationError];
    if (!profile || !profile.isVerified) {
        if (!operationError) operationError = [NSError errorWithDomain:@"DisplayStateManager" code:5
            userInfo:@{NSLocalizedDescriptionKey: @"Display profile is missing or unverified"}];
        if (error) *error = operationError;
        self.lastError = operationError.localizedDescription;
        return NO;
    }

    DDCVCPValue current = {};
    if (![self.backend readFeature:profile.featureCode identity:identity value:&current error:&operationError]) {
        if (!operationError) operationError = [NSError errorWithDomain:@"DisplayStateManager" code:6
            userInfo:@{NSLocalizedDescriptionKey: @"Unable to read original VCP value"}];
        if (error) *error = operationError;
        self.lastError = operationError.localizedDescription;
        return NO;
    }

    ManagedDisplayState *state = [ManagedDisplayState new];
    state.identity = identity;
    state.originalValue = current.currentValue;
    state.movieValue = profile.movieValue;
    state.featureCode = profile.featureCode;
    state.originallyMovie = current.currentValue == profile.movieValue;
    state.changedByPlugin = NO;
    state.restorePending = NO;
    self.states[identity] = state;

    if (state.originallyMovie) return YES;

    operationError = nil;
    if ([self.backend writeFeature:state.featureCode identity:identity value:state.movieValue error:&operationError]) {
        state.changedByPlugin = YES;
        return YES;
    }

    // A failed write may have reached the monitor despite a transport or read-back error.
    // Keep a restoration record until restoring the exact pre-acquisition value is verified.
    state.changedByPlugin = YES;
    state.restorePending = YES;
    state.lastError = operationError.localizedDescription ?: @"Movie write failed";
    self.lastError = state.lastError;
    NSError *writeError = operationError;
    if (![self restoreIdentity:identity]) {
                if (error) *error = writeError ?: [NSError errorWithDomain:@"DisplayStateManager" code:8
                    userInfo:@{NSLocalizedDescriptionKey: state.lastError ?: @"Failed to restore original value"}];
        return NO;
    }
    if (error) *error = writeError;
    return NO;
}

- (BOOL)releaseIdentity:(NSString *)identity {
    ManagedDisplayState *state = self.states[identity];
    if (!state) return YES;
    if (state.originallyMovie || !state.changedByPlugin) {
        [self.states removeObjectForKey:identity];
        return YES;
    }
    return [self restoreIdentity:identity];
}

- (BOOL)restoreIdentity:(NSString *)identity {
    ManagedDisplayState *state = self.states[identity];
    if (!state) return YES;
    if (state.originallyMovie || !state.changedByPlugin) {
        [self.states removeObjectForKey:identity];
        return YES;
    }
    NSError *restoreError = nil;
    if ([self.backend writeFeature:state.featureCode identity:identity value:state.originalValue error:&restoreError]) {
        [self.states removeObjectForKey:identity];
        return YES;
    }
    state.restorePending = YES;
    state.lastError = restoreError.localizedDescription ?: @"Original VCP restoration failed";
    self.lastError = state.lastError;
    return NO;
}

- (BOOL)retryPendingRestorations {
    [self.lock lock];
    @try {
        BOOL allRestored = YES;
        NSArray<NSString *> *identities = self.states.allKeys;
        for (NSString *identity in identities) {
            if (!self.states[identity].restorePending) continue;
            if (![self restoreIdentity:identity]) allRestored = NO;
        }
        return allRestored;
    } @finally {
        [self.lock unlock];
    }
}

- (BOOL)releaseAll {
    return [self setTargetIdentity:nil error:nil];
}

- (NSDictionary<NSString *,id> *)statusDictionary {
    [self.lock lock];
    @try {
        NSMutableArray *rows = [NSMutableArray arrayWithCapacity:self.states.count];
        for (NSString *identity in [[self.states allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            ManagedDisplayState *state = self.states[identity];
            NSString *status = state.restorePending ? @"RESTORE_PENDING" :
                (state.originallyMovie ? @"ORIGINAL_MOVIE" : @"MANAGED_MOVIE");
            NSMutableDictionary *row = [@{
                @"identity": identity,
                @"featureCode": @(state.featureCode),
                @"originalValue": @(state.originalValue),
                @"movieValue": @(state.movieValue),
                @"originallyMovie": @(state.originallyMovie),
                @"changedByPlugin": @(state.changedByPlugin),
                @"restorePending": @(state.restorePending),
                @"state": status
            } mutableCopy];
            if (state.lastError) row[@"lastError"] = state.lastError;
            [rows addObject:row];
        }
        NSUInteger pendingCount = 0;
        for (NSDictionary *row in rows) if ([row[@"restorePending"] boolValue]) pendingCount++;
        NSMutableDictionary *status = [@{
            @"targetIdentity": self.targetIdentity ?: NSNull.null,
            @"managedDisplays": rows,
            @"restorePendingCount": @(pendingCount)
        } mutableCopy];
        if (self.lastError) status[@"lastError"] = self.lastError;
        return status;
    } @finally {
        [self.lock unlock];
    }
}
@end

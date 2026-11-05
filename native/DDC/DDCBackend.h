#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    uint16_t currentValue;
    uint16_t maximumValue;
    uint8_t type;
} DDCVCPValue;

NSData *DDCGetRequest(uint8_t featureCode);
NSData *DDCSetRequest(uint8_t featureCode, uint16_t value);
BOOL DDCParseVCPReply(NSData *reply, uint8_t expectedFeature,
                      DDCVCPValue * _Nullable value, NSError * _Nullable * _Nullable error);

BOOL DDCReadVCP(NSString *identity, uint8_t featureCode, DDCVCPValue * _Nullable value,
                NSError * _Nullable * _Nullable error);
BOOL DDCWriteVCP(NSString *identity, uint8_t featureCode, uint16_t value,
                 NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol StationSipDelegate <NSObject>
- (void)sipEvent:(NSString *)state peer:(nullable NSString *)peer message:(nullable NSString *)message;
- (void)sipStats:(NSDictionary<NSString *, id> *)stats;
@end

/// Thin Objective-C wrapper over the PJSIP C API (pjsua) for EBU 3326 radio.
/// Mirrors the Android SipEngine behaviour: register, inbound/outbound calls,
/// Opus/G.722/G.711 priorities, audio routing and RTCP + level stats.
@interface StationSip : NSObject

@property (nonatomic, weak, nullable) id<StationSipDelegate> delegate;

- (void)initializeEngine;

- (void)registerWithHost:(NSString *)host
                    port:(int)port
                username:(NSString *)username
                password:(NSString *)password
               extension:(NSString *)extension
                   codec:(NSString *)codec;

- (void)acceptCall;
- (void)declineCall;
- (void)hangupCall;
- (void)dialTarget:(NSString *)target;
- (void)unregister;
- (void)dispose;

@end

NS_ASSUME_NONNULL_END

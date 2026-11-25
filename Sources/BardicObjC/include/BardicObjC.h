#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift can't catch Objective-C exceptions. AVAudioEngine raises them (e.g. a tap whose format no
/// longer matches the mic), and AppKit then swallows them mid-event, leaving the app half-way
/// through whatever it was doing.
@interface BardicObjC : NSObject

/// Runs `block`, turning an Objective-C exception into an NSError.
/// From Swift: `try BardicObjC.catchingExceptions { … }`.
+ (BOOL)catchingExceptions:(NS_NOESCAPE void (^)(void))block error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

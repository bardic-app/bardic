#import "BardicObjC.h"

@implementation BardicObjC

+ (BOOL)catchingExceptions:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"BardicObjCException" code:1 userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                @"ExceptionName": exception.name,
            }];
        }
        return NO;
    }
}

@end

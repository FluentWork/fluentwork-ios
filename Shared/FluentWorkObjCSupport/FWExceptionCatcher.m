#import "FWExceptionCatcher.h"

BOOL FWTryCatch(void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    }
    @catch (NSException *exception) {
        if (error != NULL) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name ?: @"unknown exception";
            info[@"FWExceptionName"] = exception.name ?: @"unknown";
            // Keep the first few frames: enough to tell a CoreAudio raise from
            // one of ours without shipping the whole symbol soup to the tracker.
            NSArray<NSString *> *stack = exception.callStackSymbols;
            if (stack.count > 0) {
                info[@"FWExceptionCallStack"] = [stack subarrayWithRange:NSMakeRange(0, MIN(6, stack.count))];
            }
            *error = [NSError errorWithDomain:@"FWObjCException" code:0 userInfo:info];
        }
        return NO;
    }
}

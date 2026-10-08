#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static inline NSError *CHError(NSString *message) {
    return [NSError errorWithDomain:@"chauffeur.bridge" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// dlopen handle of the loaded SimulatorKit, or NULL before +[CHSimulator loadFrameworks…].
void *_Nullable CHSimulatorKitHandle(void);

NS_ASSUME_NONNULL_END

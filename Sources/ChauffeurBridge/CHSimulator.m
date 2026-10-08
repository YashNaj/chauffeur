#import "ChauffeurBridge.h"
#import "CHInternal.h"
#import <dlfcn.h>

NSString *const CHBridgeErrorDomain = @"chauffeur.bridge";

static void *gSimulatorKit;
static NSString *gSimulatorKitPath;
void *CHSimulatorKitHandle(void) { return gSimulatorKit; }

@interface NSObject (CHCoreSimulatorPrivate)
+ (id)sharedServiceContextForDeveloperDir:(NSString *)dir error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
@end

@implementation CHSimulator {
    id _device;
}

+ (NSString *)loadFrameworksWithDeveloperDir:(NSString *)dir error:(NSError **)error {
    @synchronized (self) {
        if (gSimulatorKit) return gSimulatorKitPath;
        if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW)) {
            if (error) *error = CHError([NSString stringWithFormat:@"cannot load CoreSimulator: %s", dlerror()]);
            return nil;
        }
        NSArray<NSString *> *candidates = @[
            [dir stringByAppendingPathComponent:@"Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"],
            [[dir stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:@"SharedFrameworks/SimulatorKit.framework/SimulatorKit"],
        ];
        for (NSString *path in candidates) {
            void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW);
            if (handle) {
                gSimulatorKit = handle;
                gSimulatorKitPath = path;
                return path;
            }
        }
        if (error) *error = CHError([NSString stringWithFormat:
            @"SimulatorKit not found under %@ (PrivateFrameworks or ../SharedFrameworks); check xcode-select -p", dir]);
        return nil;
    }
}

+ (instancetype)simulatorWithUDID:(NSString *)udid developerDir:(NSString *)dir error:(NSError **)error {
    if (![self loadFrameworksWithDeveloperDir:dir error:error]) return nil;
    Class contextClass = NSClassFromString(@"SimServiceContext");
    if (!contextClass) {
        if (error) *error = CHError(@"SimServiceContext missing from CoreSimulator");
        return nil;
    }
    NSError *inner = nil;
    id context = [contextClass sharedServiceContextForDeveloperDir:dir error:&inner];
    id set = context ? [context defaultDeviceSetWithError:&inner] : nil;
    if (!set) {
        if (error) *error = CHError([NSString stringWithFormat:@"no simulator device set: %@", inner.localizedDescription]);
        return nil;
    }
    for (id device in [set valueForKey:@"availableDevices"]) {
        if ([[[device valueForKey:@"UDID"] UUIDString] caseInsensitiveCompare:udid] == NSOrderedSame) {
            CHSimulator *simulator = [self new];
            simulator->_device = device;
            return simulator;
        }
    }
    if (error) *error = CHError([NSString stringWithFormat:@"simulator %@ not found; list them with: xcrun simctl list devices", udid]);
    return nil;
}

- (id)device { return _device; }
- (NSString *)udid { return [[_device valueForKey:@"UDID"] UUIDString]; }
- (NSString *)name { return [_device valueForKey:@"name"]; }
- (BOOL)isBooted { return [[_device valueForKey:@"state"] unsignedIntegerValue] == 3; }

- (NSString *)runtimeVersion {
    NSString *version = [[_device valueForKey:@"runtime"] valueForKey:@"versionString"];
    return version ?: @"?";
}

- (CGSize)pointSize {
    id type = [_device valueForKey:@"deviceType"];
    CGSize pixels = [[type valueForKey:@"mainScreenSize"] sizeValue];
    double scale = [[type valueForKey:@"mainScreenScale"] doubleValue];
    return scale > 0 ? CGSizeMake(pixels.width / scale, pixels.height / scale) : CGSizeZero;
}

@end

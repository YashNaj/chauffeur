// Accessibility tree via AXPTranslator. Bridge-delegate recipe adapted from baguette (Apache-2.0) and idb.
#import "ChauffeurBridge.h"
#import "CHInternal.h"
#import <AppKit/AppKit.h>
#import <dlfcn.h>

@interface NSObject (CHAXPrivate)
+ (id)sharedInstance;
+ (id)emptyResponse;
- (id)frontmostApplicationWithDisplayId:(unsigned int)displayId bridgeDelegateToken:(NSString *)token;
- (id)objectAtPoint:(CGPoint)point displayId:(unsigned int)displayId bridgeDelegateToken:(NSString *)token;
- (id)macPlatformElementFromTranslation:(id)translation;
- (void)sendAccessibilityRequestAsync:(id)request completionQueue:(dispatch_queue_t)queue completionHandler:(void (^)(id))handler;
- (id)translationResponse;
- (void)setRequestType:(NSInteger)t;
- (void)setParameters:(id)p;
@end

static const int kMaxDepth = 60;

/// Answers AXPTranslator's callbacks by forwarding each request to the device over XPC.
@interface CHAXBridge : NSObject
@property (strong) id device;
@end

@implementation CHAXBridge
- (id)accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token {
    id device = self.device;
    return ^id(id request) {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block id response = nil;
        [device sendAccessibilityRequestAsync:request
                              completionQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
                            completionHandler:^(id r) { response = r; dispatch_semaphore_signal(done); }];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0 || !response) {
            return [NSClassFromString(@"AXPTranslatorResponse") emptyResponse];
        }
        return response;
    };
}
- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect withToken:(NSString *)token { return rect; }
- (id)accessibilityTranslationRootParentWithToken:(NSString *)token { return nil; }
@end

static id CHValue(id element, NSString *key) {
    @try { return [element valueForKey:key]; } @catch (NSException *e) { return nil; }
}

static NSString *CHString(id element, NSString *key) {
    id v = CHValue(element, key);
    if ([v isKindOfClass:NSString.class] && [(NSString *)v length] > 0) return v;
    if ([v isKindOfClass:NSNumber.class]) return [(NSNumber *)v stringValue];
    return nil;
}

@implementation CHAXReader {
    CHAXBridge *_bridge;
    id _translator;
}

- (instancetype)initWithSimulator:(CHSimulator *)simulator error:(NSError **)error {
    if (!(self = [super init])) return nil;
    if (!dlopen("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation",
                RTLD_NOW | RTLD_GLOBAL)) {
        if (error) *error = CHError(@"cannot load AccessibilityPlatformTranslation");
        return nil;
    }
    _translator = [NSClassFromString(@"AXPTranslator") sharedInstance];
    if (!_translator) {
        if (error) *error = CHError(@"AXPTranslator unavailable");
        return nil;
    }
    _bridge = [CHAXBridge new];
    _bridge.device = simulator.device;
    [_translator setValue:_bridge forKey:@"bridgeTokenDelegate"];
    return self;
}

- (NSDictionary *)frontmostTree {
    NSString *token = NSUUID.UUID.UUIDString;
    id translation = [_translator frontmostApplicationWithDisplayId:0 bridgeDelegateToken:token];
    if (!translation) return nil;
    [translation setValue:token forKey:@"bridgeDelegateToken"];
    id root = [_translator macPlatformElementFromTranslation:translation];
    return root ? [self walk:root token:token depth:0] : nil;
}

- (pid_t)frontmostPid {
    id translation = [_translator frontmostApplicationWithDisplayId:0 bridgeDelegateToken:NSUUID.UUID.UUIDString];
    if (!translation) return 0;
    @try { return [[translation valueForKey:@"pid"] intValue]; } @catch (NSException *e) { return 0; }
}

- (NSDictionary *)elementAtPoint:(CGPoint)point {
    NSString *token = NSUUID.UUID.UUIDString;
    id hit = [_translator objectAtPoint:point displayId:0 bridgeDelegateToken:token];
    if (!hit) return nil;
    [hit setValue:token forKey:@"bridgeDelegateToken"];
    id element = [_translator macPlatformElementFromTranslation:hit];
    return element ? [self walk:element token:token depth:kMaxDepth] : nil;
}

- (NSDictionary *)treeForPid:(pid_t)pid {
    Class requestClass = NSClassFromString(@"AXPTranslatorRequest");
    if (!requestClass) return nil;
    NSString *token = NSUUID.UUID.UUIDString;
    id request = [requestClass new];
    @try {
        [request setValue:@1 forKey:@"requestType"];
        [request setValue:@{@"pid": @(pid)} forKey:@"parameters"];
    } @catch (NSException *e) { return nil; }
    id (^send)(id) = [_bridge accessibilityTranslationDelegateBridgeCallbackWithToken:token];
    id translation = CHValue(send(request), @"translationResponse");
    if (!translation) return nil;
    [translation setValue:token forKey:@"bridgeDelegateToken"];
    id root = [_translator macPlatformElementFromTranslation:translation];
    return root ? [self walk:root token:token depth:0] : nil;
}

- (NSDictionary *)walk:(id)element token:(NSString *)token depth:(int)depth {
    @try { [CHValue(element, @"translation") setValue:token forKey:@"bridgeDelegateToken"]; } @catch (NSException *e) {}
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, NSString *> *keys = @{
        @"role": @"accessibilityRole", @"subrole": @"accessibilitySubrole", @"label": @"accessibilityLabel",
        @"value": @"accessibilityValue", @"identifier": @"accessibilityIdentifier", @"title": @"accessibilityTitle",
        @"placeholder": @"accessibilityPlaceholderValue",
    };
    for (NSString *key in keys) {
        NSString *s = CHString(element, keys[key]);
        if (s) d[key] = s;
    }
    if (!d[@"role"]) d[@"role"] = @"AXUnknown";
    id enabled = CHValue(element, @"accessibilityEnabled"), hidden = CHValue(element, @"accessibilityHidden");
    d[@"enabled"] = @([enabled isKindOfClass:NSNumber.class] ? [enabled boolValue] : YES);
    d[@"hidden"] = @([hidden isKindOfClass:NSNumber.class] ? [hidden boolValue] : NO);
    CGRect f = [element respondsToSelector:@selector(accessibilityFrame)] ? [element accessibilityFrame] : CGRectZero;
    d[@"frame"] = @[@(f.origin.x), @(f.origin.y), @(f.size.width), @(f.size.height)];
    NSMutableArray *children = [NSMutableArray array];
    if (depth < kMaxDepth) {
        id kids = CHValue(element, @"accessibilityChildren");
        if ([kids isKindOfClass:NSArray.class]) {
            for (id child in kids) [children addObject:[self walk:child token:token depth:depth + 1]];
        }
    }
    d[@"children"] = children;
    return d;
}

@end

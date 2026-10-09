// Per-connection statistics via the private NetworkStatistics framework (what nettop uses), loaded with dlopen so
// the build doesn't link a private framework. Signatures from step 0's probe (M4b Findings §1).
#import "ChauffeurBridge.h"
#import "CHInternal.h"
#import <dlfcn.h>
#import <netdb.h>
#import <sys/socket.h>

typedef void *CHNStatManager;
typedef void *CHNStatSource;
typedef CHNStatManager (*CHCreateFn)(CFAllocatorRef, dispatch_queue_t, void (^)(CHNStatSource, void *));
typedef void (*CHManagerFn)(CHNStatManager);
typedef void (*CHQueryAllFn)(CHNStatManager, void (^)(void));
typedef void (*CHSourceDictFn)(CHNStatSource, void (^)(CFDictionaryRef));
typedef void (*CHSourceVoidFn)(CHNStatSource, void (^)(void));
typedef void (*CHSourceFn)(CHNStatSource);

static uint64_t CHNowMs(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000; }

/// "ip:port" for a sockaddr; empty for an unset address.
static NSString *CHEndpoint(id value) {
    NSData *data = [value isKindOfClass:NSData.class] ? value : nil;
    if (data.length < sizeof(struct sockaddr)) return @"";
    const struct sockaddr *sa = data.bytes;
    char host[NI_MAXHOST] = {0}, port[NI_MAXSERV] = {0};
    if (getnameinfo(sa, (socklen_t)data.length, host, sizeof host, port, sizeof port, NI_NUMERICHOST | NI_NUMERICSERV))
        return @"";
    if (strcmp(port, "0") == 0) return @"";
    return sa->sa_family == AF_INET6 ? [NSString stringWithFormat:@"[%s]:%s", host, port]
                                     : [NSString stringWithFormat:@"%s:%s", host, port];
}

@implementation CHNetStats {
    dispatch_queue_t _queue;
    CHNStatManager _manager;
    CHQueryAllFn _queryAll;
    CHManagerFn _destroy;
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *_flows;  // only touched on _queue
    uint64_t _nextId;
}

+ (nullable instancetype)statsWithError:(NSError **)error {
    return [[self alloc] initWithError:error];
}

- (nullable instancetype)initWithError:(NSError **)error {
    if (!(self = [super init])) return nil;
    void *lib = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_LAZY);
    CHCreateFn create = lib ? (CHCreateFn)dlsym(lib, "NStatManagerCreate") : NULL;
    CHManagerFn addTCP = lib ? (CHManagerFn)dlsym(lib, "NStatManagerAddAllTCP") : NULL;
    CHManagerFn addUDP = lib ? (CHManagerFn)dlsym(lib, "NStatManagerAddAllUDP") : NULL;
    CHSourceDictFn setDescription = lib ? (CHSourceDictFn)dlsym(lib, "NStatSourceSetDescriptionBlock") : NULL;
    CHSourceDictFn setCounts = lib ? (CHSourceDictFn)dlsym(lib, "NStatSourceSetCountsBlock") : NULL;
    CHSourceVoidFn setRemoved = lib ? (CHSourceVoidFn)dlsym(lib, "NStatSourceSetRemovedBlock") : NULL;
    CHSourceFn queryDescription = lib ? (CHSourceFn)dlsym(lib, "NStatSourceQueryDescription") : NULL;
    _queryAll = lib ? (CHQueryAllFn)dlsym(lib, "NStatManagerQueryAllSources") : NULL;
    _destroy = lib ? (CHManagerFn)dlsym(lib, "NStatManagerDestroy") : NULL;
    if (!create || !addTCP || !addUDP || !setDescription || !setCounts || !setRemoved || !queryDescription ||
        !_queryAll || !_destroy) {
        if (error) *error = CHError(@"NetworkStatistics is unavailable on this Mac");
        return nil;
    }
    _queue = dispatch_queue_create("chauffeur.netstats", DISPATCH_QUEUE_SERIAL);
    _flows = [NSMutableDictionary dictionary];
    __weak CHNetStats *weakSelf = self;
    _manager = create(kCFAllocatorDefault, _queue, ^(CHNStatSource source, void *unused) {
        CHNetStats *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSNumber *key = @(++strongSelf->_nextId);
        NSMutableDictionary *flow = [@{@"id": key, @"openedMs": @(CHNowMs()), @"tx": @0, @"rx": @0} mutableCopy];
        strongSelf->_flows[key] = flow;
        setDescription(source, ^(CFDictionaryRef d) { [CHNetStats update:flow from:(__bridge NSDictionary *)d]; });
        setCounts(source, ^(CFDictionaryRef c) { [CHNetStats update:flow from:(__bridge NSDictionary *)c]; });
        setRemoved(source, ^{ flow[@"closedMs"] = @(CHNowMs()); });
        queryDescription(source);
    });
    if (!_manager) {
        if (error) *error = CHError(@"NetworkStatistics refused a manager");
        return nil;
    }
    addTCP(_manager);
    addUDP(_manager);
    return self;
}

/// A description or counts dictionary: whichever keys it has.
+ (void)update:(NSMutableDictionary *)flow from:(NSDictionary *)d {
    if ([d[@"processID"] isKindOfClass:NSNumber.class]) flow[@"pid"] = d[@"processID"];
    if ([d[@"processName"] isKindOfClass:NSString.class]) flow[@"process"] = d[@"processName"];
    if ([d[@"provider"] isKindOfClass:NSString.class]) flow[@"provider"] = d[@"provider"];
    if (d[@"remoteAddress"]) {
        NSString *remote = CHEndpoint(d[@"remoteAddress"]);
        if (remote.length) flow[@"remote"] = remote;
    }
    if ([d[@"txBytes"] isKindOfClass:NSNumber.class]) flow[@"tx"] = d[@"txBytes"];
    if ([d[@"rxBytes"] isKindOfClass:NSNumber.class]) flow[@"rx"] = d[@"rxBytes"];
}

- (NSArray<NSDictionary<NSString *, id> *> *)flowsForPids:(NSArray<NSNumber *> *)pids {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    _queryAll(_manager, ^{ dispatch_semaphore_signal(done); });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC));
    NSSet<NSNumber *> *wanted = [NSSet setWithArray:pids];
    NSMutableArray *out = [NSMutableArray array];
    dispatch_sync(_queue, ^{
        uint64_t now = CHNowMs();
        NSMutableArray *expired = [NSMutableArray array];
        [self->_flows enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSMutableDictionary *flow, BOOL *stop) {
            NSNumber *closed = flow[@"closedMs"];
            if (closed && now - closed.unsignedLongLongValue > 120000) {
                [expired addObject:key];
                return;
            }
            if (flow[@"pid"] && [wanted containsObject:flow[@"pid"]]) [out addObject:[flow copy]];
        }];
        [self->_flows removeObjectsForKeys:expired];
    });
    return out;
}

- (void)dealloc {
    if (_manager && _destroy) _destroy(_manager);
}
@end

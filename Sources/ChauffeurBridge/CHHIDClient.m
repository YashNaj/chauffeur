// Touch and keyboard input over SimDeviceLegacyHIDClient.
// Digitizer and HID page-7 recipes adapted from baguette (Apache-2.0).
#import "ChauffeurBridge.h"
#import "CHInternal.h"
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <malloc/malloc.h>

typedef CFTypeRef CHHIDEventRef;
typedef CHHIDEventRef (*CreateDigitizerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                                           double, double, double, double, double, Boolean, Boolean, uint32_t);
typedef CHHIDEventRef (*CreateFingerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                        double, double, double, double, double, Boolean, Boolean, uint32_t);
typedef void (*AppendFn)(CHHIDEventRef, CHHIDEventRef, uint32_t);
typedef uint8_t *(*WrapFn)(CHHIDEventRef);
typedef void *(*MouseFn)(const CGPoint *, const CGPoint *, uint32_t, uint32_t, uint32_t, double, double, double, double);
typedef void *(*ArbitraryFn)(uint32_t, uint32_t, uint32_t, uint32_t);
typedef void *(*ButtonFn)(uint32_t, uint32_t, uint32_t);
typedef void *(*ServiceFn)(void);

@interface NSObject (CHSimulatorKitPrivate)
- (instancetype)initWithDevice:(id)device error:(NSError **)error;
- (void)sendWithMessage:(void *)message freeWhenDone:(BOOL)freeWhenDone
        completionQueue:(dispatch_queue_t)queue completion:(void (^)(NSError *))completion;
@end

static const uint32_t kTarget = 0x32;
static const uint32_t kButtonTarget = 0x33;  // hardware buttons (idb's ButtonEventTargetHardware)

@implementation CHHIDClient {
    id _client;
    dispatch_queue_t _queue;
    CreateDigitizerFn _createDigitizer;
    CreateFingerFn _createFinger;
    AppendFn _append;
    WrapFn _wrap;
    MouseFn _mouse;
    ArbitraryFn _arbitrary;
    ButtonFn _button;
}

- (instancetype)initWithSimulator:(CHSimulator *)simulator error:(NSError **)error {
    if (!(self = [super init])) return nil;
    void *kit = CHSimulatorKitHandle();
    Class cls = NSClassFromString(@"_TtC12SimulatorKit24SimDeviceLegacyHIDClient");
    if (!kit || !cls) {
        if (error) *error = CHError(@"SimDeviceLegacyHIDClient missing from SimulatorKit");
        return nil;
    }
    NSError *inner = nil;
    _client = [[cls alloc] initWithDevice:simulator.device error:&inner];
    if (!_client) {
        if (error) *error = CHError([NSString stringWithFormat:@"HID client: %@", inner.localizedDescription]);
        return nil;
    }
    _queue = dispatch_queue_create("chauffeur.hid", DISPATCH_QUEUE_SERIAL);
    _createDigitizer = (CreateDigitizerFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
    _createFinger = (CreateFingerFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
    _append = (AppendFn)dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
    _wrap = (WrapFn)dlsym(kit, "IndigoHIDMessageForTrackpadEventFromHIDEventRef");
    _mouse = (MouseFn)dlsym(kit, "IndigoHIDMessageForMouseNSEvent");
    _arbitrary = (ArbitraryFn)dlsym(kit, "IndigoHIDMessageForHIDArbitrary");
    _button = (ButtonFn)dlsym(kit, "IndigoHIDMessageForButton");  // optional: without it only buttons fail
    if (!_createDigitizer || !_createFinger || !_append || !_wrap || !_mouse || !_arbitrary) {
        if (error) *error = CHError(@"HID message symbols missing from IOKit/SimulatorKit");
        return nil;
    }
    for (NSString *name in @[@"IndigoHIDMessageToCreatePointerService", @"IndigoHIDMessageToCreateMouseService"]) {
        ServiceFn fn = (ServiceFn)dlsym(kit, name.UTF8String);
        void *message = fn ? fn() : NULL;
        if (message) {
            [self send:message];
            usleep(20000);
        }
    }
    return self;
}

/// YES once the Mach send completes. That proves transport only, not consumption (the Verifier checks that).
- (BOOL)send:(void *)message {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError *failure = nil;
    [_client sendWithMessage:message freeWhenDone:YES completionQueue:_queue completion:^(NSError *e) {
        failure = e;
        dispatch_semaphore_signal(done);
    }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) return NO;
    return failure == nil;
}

- (BOOL)digitizerAt:(CGPoint)p touching:(BOOL)touching {
    uint32_t mask = touching ? 0x07 : 0x06;  // Range|Touch|Position vs Touch|Position
    uint64_t now = mach_absolute_time();
    CHHIDEventRef parent = _createDigitizer(kCFAllocatorDefault, now, 2, 0, 1, mask, 0, p.x, p.y, 0, 0, 0, touching, touching, 0);
    if (!parent) return NO;
    CHHIDEventRef finger = _createFinger(kCFAllocatorDefault, now, 0, 1, mask, p.x, p.y, 0, 0, 0, touching, touching, 0);
    if (finger) {
        _append(parent, finger, 0);
        CFRelease(finger);
    }
    uint8_t *message = _wrap(parent);
    CFRelease(parent);
    if (!message) return NO;
    size_t size = malloc_size(message);
    memcpy(message + 0x6c, &kTarget, sizeof kTarget);
    if (size >= 0x110) memcpy(message + 0x10c, &kTarget, sizeof kTarget);
    message[0x3a] = 0; message[0x3b] = 0;  // interior touch, no edge
    if (size >= 0xdc) { message[0xda] = 0; message[0xdb] = 0; }
    return [self send:message];
}

- (BOOL)mouseAt:(CGPoint)p down:(BOOL)down {
    NSAssert(NSThread.isMainThread, @"IndigoHIDMessageForMouseNSEvent reads AppKit thread state");
    CGPoint point = p;
    void *message = _mouse(&point, NULL, kTarget, down ? 1 : 2, down ? 1 : 2, 1, 1, 1, 1);
    return message ? [self send:message] : NO;
}

- (BOOL)keyUsage:(uint32_t)usage down:(BOOL)down {
    void *message = _arbitrary(kTarget, 7, usage, down ? 1 : 2);
    return message ? [self send:message] : NO;
}

// Xcode 27's IndigoHIDMessageForButton stores its three arguments at payload offsets 0x30 (event source),
// 0x34 (direction: 1 down, 2 up) and 0x38 (target), the layout idb uses.
- (BOOL)buttonSource:(uint32_t)source down:(BOOL)down {
    if (!_button) return NO;
    void *message = _button(source, down ? 1 : 2, kButtonTarget);
    return message ? [self send:message] : NO;
}

- (BOOL)usagePage:(uint32_t)page usage:(uint32_t)usage down:(BOOL)down {
    void *message = _arbitrary(kTarget, page, usage, down ? 1 : 2);
    return message ? [self send:message] : NO;
}

@end

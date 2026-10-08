// Private-framework surface for chauffeur. Everything that calls CoreSimulator, SimulatorKit or
// AccessibilityPlatformTranslation lives in this target (spec §4 rule).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CHBridgeErrorDomain;

/// A CoreSimulator device, resolved through the selected Xcode's frameworks.
@interface CHSimulator : NSObject
/// Loads CoreSimulator and SimulatorKit (Xcode's PrivateFrameworks, or ../SharedFrameworks on Xcode 27).
/// Returns the SimulatorKit path. Safe to call repeatedly.
+ (nullable NSString *)loadFrameworksWithDeveloperDir:(NSString *)developerDir error:(NSError **)error
    NS_SWIFT_NAME(loadFrameworks(developerDir:));
+ (nullable instancetype)simulatorWithUDID:(NSString *)udid developerDir:(NSString *)developerDir error:(NSError **)error
    NS_SWIFT_NAME(init(udid:developerDir:));
@property (readonly) id device;
@property (readonly) NSString *udid;
@property (readonly) NSString *name;
@property (readonly) NSString *runtimeVersion;
@property (readonly, getter=isBooted) BOOL booted;
/// Screen size in points: the device type's pixel size divided by its scale.
@property (readonly) CGSize pointSize;
@end

/// The frontmost app's accessibility tree, via AccessibilityPlatformTranslation and the device's XPC channel.
/// Elements are dictionaries: role, subrole, label, value, identifier, title, placeholder (NSString, optional),
/// enabled, hidden (NSNumber), frame (NSArray of 4 NSNumber, points), children (NSArray of elements).
@interface CHAXReader : NSObject
- (nullable instancetype)initWithSimulator:(CHSimulator *)simulator error:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)frontmostTree;
/// The element under a point, without children.
- (nullable NSDictionary<NSString *, id> *)elementAtPoint:(CGPoint)point NS_SWIFT_NAME(element(at:));
/// The accessibility tree of one process, whatever is in front (AXPTranslatorRequest type 1 with a pid).
- (nullable NSDictionary<NSString *, id> *)treeForPid:(pid_t)pid NS_SWIFT_NAME(tree(pid:));
@end

/// SimulatorKit's legacy HID client: touches and keys into one simulator. Points are normalised 0–1 (portrait).
@interface CHHIDClient : NSObject
- (nullable instancetype)initWithSimulator:(CHSimulator *)simulator error:(NSError **)error;
/// IOHIDEvent digitizer + finger, wrapped for the guest; an interior touch (edge bytes cleared).
- (BOOL)digitizerAt:(CGPoint)point touching:(BOOL)touching NS_SWIFT_NAME(digitizer(at:touching:));
/// 9-argument IndigoHIDMessageForMouseNSEvent. Main thread only.
- (BOOL)mouseAt:(CGPoint)point down:(BOOL)down NS_SWIFT_NAME(mouse(at:down:));
/// HID page-7 key.
- (BOOL)keyUsage:(uint32_t)usage down:(BOOL)down NS_SWIFT_NAME(key(usage:down:));
/// A hardware button: IndigoHIDMessageForButton(source, direction, target 0x33). Sources (idb's values): home 0x0,
/// lock 0x1, siri 0x400002. NO when SimulatorKit lacks the symbol or the send fails.
- (BOOL)buttonSource:(uint32_t)source down:(BOOL)down NS_SWIFT_NAME(button(source:down:));
/// A HID usage on any page (consumer page 0x0C for volume), like `key` but with the page given.
- (BOOL)usagePage:(uint32_t)page usage:(uint32_t)usage down:(BOOL)down NS_SWIFT_NAME(usage(page:usage:down:));
@end

NS_ASSUME_NONNULL_END

#import <UIKit/UIKit.h>
#import <UIKit/UIApplication+Private.h>
#import <UIKit/UIStatusBar.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

static NSString * const LWOverlayTag = @"com.user.lilywhite.overlay";
static BOOL LWHasWiFi;
static NSInteger LWSignalBars = 0;

#ifndef LILYWHITE_DEBUG
#define LILYWHITE_DEBUG 0
#endif

static NSDateFormatter *LWTimeFormatter(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"HH:mm";
    });
    return formatter;
}

static __attribute__((unused)) NSInteger LWVisibleSignalLayers(CALayer *layer) {
    NSInteger count = 0;
    for (CALayer *child in layer.sublayers ?: @[]) {
        if (child.hidden || child.opacity <= 0.01) continue;
        if (child.bounds.size.width > 1.0 && child.bounds.size.height > 1.0) count++;
        count += LWVisibleSignalLayers(child);
    }
    return MIN(4, count);
}

@interface LWStatusCapsule : UIView
@property(nonatomic, strong) UILabel *timeLabel;
@property(nonatomic, strong) UILabel *signalLabel;
@property(nonatomic, strong) UIImageView *wifiImage;
@property(nonatomic, strong) UIView *pillView;
@property(nonatomic, strong) UIView *signalDock;
@property(nonatomic, strong) CAShapeLayer *batteryOutlineLayer;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, assign) CGFloat batteryFraction;
@property(nonatomic, strong) NSDate *batteryPercentageVisibleUntil;
- (void)showBatteryPercentage;
- (void)handleNativeStatusBarAction:(UIGestureRecognizer *)recognizer;
@end

@implementation LWStatusCapsule

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.tag = 17012;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.pillView = [[UIView alloc] initWithFrame:CGRectZero];
    self.pillView.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.86];
    self.pillView.layer.cornerCurve = kCACornerCurveContinuous;
    self.pillView.userInteractionEnabled = NO;
    [self addSubview:self.pillView];

    self.timeLabel = [self labelWithFont:[UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold]];
    self.signalLabel = [self labelWithFont:[UIFont systemFontOfSize:6 weight:UIFontWeightSemibold]];
    self.wifiImage = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"wifi"]];
    self.wifiImage.tintColor = UIColor.whiteColor;
    self.wifiImage.contentMode = UIViewContentModeScaleAspectFit;
    self.signalDock = [[UIView alloc] initWithFrame:CGRectZero];
    self.signalDock.backgroundColor = UIColor.clearColor;
    self.signalDock.hidden = YES;
    self.signalDock.layer.cornerCurve = kCACornerCurveContinuous;
    self.signalDock.userInteractionEnabled = NO;
    [self addSubview:self.signalDock];
    self.batteryOutlineLayer = [CAShapeLayer layer];
    self.batteryOutlineLayer.fillColor = UIColor.clearColor.CGColor;
    self.batteryOutlineLayer.lineWidth = 1.8;
    [self.layer addSublayer:self.batteryOutlineLayer];
    [self.pillView addSubview:self.timeLabel];
    [self.signalDock addSubview:self.signalLabel];
    [self addSubview:self.wifiImage];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [self addGestureRecognizer:tap];
    [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
    [self updateContent];
    return self;
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    [super willMoveToWindow:newWindow];

    if (!newWindow) {
        [self.timer invalidate];
        self.timer = nil;
        return;
    }

    if (!self.timer) {
        __weak typeof(self) weakSelf = self;
        self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                    repeats:YES
                                                      block:^(__unused NSTimer *timer) {
            [weakSelf updateContent];
        }];
    }

    [self updateContent];
}

- (void)dealloc {
    [self.timer invalidate];
}

- (UILabel *)labelWithFont:(UIFont *)font {
    UILabel *label = [UILabel new];
    label.textColor = UIColor.whiteColor;
    label.font = font;
    label.textAlignment = NSTextAlignmentCenter;
    label.adjustsFontSizeToFitWidth = YES;
    return label;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height;
    // The capsule is one shape; the bottom-center dock sits inside it and
    // masks the border to create a real notch instead of hanging below.
    CGFloat pillHeight = h;
    self.pillView.frame = self.bounds;
    self.pillView.layer.cornerRadius = pillHeight / 2.0;
    CGFloat wifiOffset = self.wifiImage.hidden ? 0.0 : 12.0;
    self.timeLabel.frame = CGRectMake(wifiOffset, 0.0, MAX(8.0, self.bounds.size.width - wifiOffset), pillHeight);
    self.wifiImage.frame = CGRectMake(6.0, 3.0, 13.0, 13.0);
    CGRect outline = CGRectInset(self.pillView.bounds, 1.5, 1.5);
    self.batteryOutlineLayer.frame = self.pillView.bounds;
    self.batteryOutlineLayer.path = [UIBezierPath bezierPathWithRoundedRect:outline cornerRadius:CGRectGetHeight(outline) / 2.0].CGPath;
    self.batteryOutlineLayer.mask = nil;
    // Keep the charged end fixed on the right: as charge falls, the outline
    // retracts from left to right instead of growing left to right.
    CGFloat visibleFraction = MIN(1.0, MAX(0.04, self.batteryFraction));
    self.batteryOutlineLayer.strokeStart = 1.0 - visibleFraction;
    self.batteryOutlineLayer.strokeEnd = 1.0;
    UIDeviceBatteryState batteryState = UIDevice.currentDevice.batteryState;
    BOOL charging = batteryState == UIDeviceBatteryStateCharging ||
                    batteryState == UIDeviceBatteryStateFull;
    UIColor *color = charging ? UIColor.systemGreenColor : (NSProcessInfo.processInfo.lowPowerModeEnabled ? UIColor.systemYellowColor : UIColor.whiteColor);
    self.batteryOutlineLayer.strokeColor = color.CGColor;
}

- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeMake(108.0, size.height);
}

- (void)handleTap:(__unused UITapGestureRecognizer *)recognizer {
    [self showBatteryPercentage];
}

- (void)showBatteryPercentage {
    self.batteryPercentageVisibleUntil = [NSDate dateWithTimeIntervalSinceNow:3.0];
    [self updateContent];
}

- (void)handleNativeStatusBarAction:(UIGestureRecognizer *)recognizer {
    UIWindow *window = recognizer.view.window ?: self.window;
    if (!window || recognizer.state != UIGestureRecognizerStateEnded) return;
    CGPoint point = [recognizer locationInView:window];
    CGRect capsuleFrame = [self convertRect:self.bounds toView:window];
    if (CGRectContainsPoint(capsuleFrame, point)) [self showBatteryPercentage];
}

- (void)updateContent {
    // Do not instantiate CoreTelephony from SpringBoard. It is not needed for
    // the visual smoke test and keeps this build independent of its service
    // lifecycle during SpringBoard launch.
    self.signalLabel.hidden = YES;
    self.wifiImage.hidden = !LWHasWiFi;

    UIDevice *device = UIDevice.currentDevice;
    self.batteryFraction = device.batteryLevel >= 0.0 ? MIN(1.0, MAX(0.0, device.batteryLevel)) : 1.0;
    if ([self.batteryPercentageVisibleUntil timeIntervalSinceNow] > 0.0) {
        NSInteger percentage = (NSInteger)(self.batteryFraction * 100.0 + 0.5);
        self.timeLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percentage];
    } else {
        self.batteryPercentageVisibleUntil = nil;
        self.timeLabel.text = [LWTimeFormatter() stringFromDate:NSDate.date];
    }
    [self setNeedsLayout];
    [self setNeedsDisplay];
}

@end

static LWStatusCapsule *LWCapsule;
static UIStatusBar *LWStatusBar;
static __weak UIWindow *LWStatusWindow;
static CGFloat LWNativeTimeHeight;
static CGRect LWNativeTimeRect;
static UIView *LWNativeTimeView;
static NSString *LWRuntimeMap;
static NSString *LWTouchRuntimeMap;
static char LWNativeCapsuleKey;
static char LWNativeActionTargetKey;
static BOOL LWNotificationMapCaptured;
static UIView *LWNotificationTray;
static __weak UIView *LWNativeRightAnchor;
static __weak UIView *LWNativeRightHost;
static __weak UIWindow *LWNativeRightWindow;
static __weak UIView *LWPreviousRightAnchor;
static __weak UIView *LWPreviousRightHost;
static __weak UIWindow *LWPreviousRightWindow;
static BOOL LWReconcilingNotifications;
static NSMutableDictionary<NSString *, NSDictionary *> *LWNotificationRequests;
static NSMutableArray<NSString *> *LWNotificationOrder;
static NSMutableDictionary<NSString *, UIImage *> *LWNotificationIconCache;
static char LWNativeRightHiddenKey;

static void LWStartRuntimeSocket(void);
static void LWStartTouchRuntimeSocket(void);

static void LWAttachNativeStatusBarAction(UIView *item, LWStatusCapsule *capsule) {
    for (UIView *ancestor = item; ancestor; ancestor = ancestor.superview) {
        for (UIGestureRecognizer *gesture in ancestor.gestureRecognizers ?: @[]) {
            if (![NSStringFromClass(gesture.class) containsString:@"STUIStatusBarActionGestureRecognizer"]) continue;
            if (objc_getAssociatedObject(gesture, &LWNativeActionTargetKey)) continue;
            [gesture addTarget:capsule action:@selector(handleNativeStatusBarAction:)];
            objc_setAssociatedObject(gesture, &LWNativeActionTargetKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static __attribute__((unused)) BOOL LWIsSpringBoardProcess(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}

static void LWWriteNotificationRuntimeMap(void) {
    int count = objc_getClassList(NULL, 0);
    Class __unsafe_unretained *classes = (Class __unsafe_unretained *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"bulletin"] || [lower containsString:@"notification"] ||
            [lower containsString:@"banner"] || [lower containsString:@"bbserver"]) {
            [names addObject:name];
        }
    }
    free(classes);
    NSMutableString *output = [NSMutableString stringWithString:[[names sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@"\n"]];
    [output appendString:@"\n\n--- TARGET METHODS ---\n"];
    for (NSString *className in @[@"BBServer", @"BBBulletin", @"BBBulletinRequest", @"SBBulletinLocalObserverGateway", @"SBNCNotificationDispatcher", @"NCNotificationMasterList", @"NCNotificationRequest", @"SBApplicationController", @"SBApplication", @"SBApplicationIcon"]) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        [output appendFormat:@"\n[%@]\n", className];
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int i = 0; i < methodCount; i++) [output appendFormat:@"- %@\n", NSStringFromSelector(method_getName(methods[i]))];
        free(methods);
    }
    LWRuntimeMap = output;
    [output writeToFile:@"/var/mobile/Library/Preferences/LilywhiteNotificationRuntime.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void LWDescribeStatusBarTouchView(UIView *view, NSUInteger depth, NSMutableString *output) {
    if (!view || depth > 4) return;
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    NSMutableArray<NSString *> *gestures = [NSMutableArray array];
    for (UIGestureRecognizer *gesture in view.gestureRecognizers ?: @[]) {
        [gestures addObject:NSStringFromClass(gesture.class)];
    }
    [output appendFormat:@"%@%@ frame=%@ enabled=%d hidden=%d gestures=%@\n", indent,
     NSStringFromClass(view.class), NSStringFromCGRect(view.frame), view.userInteractionEnabled,
     view.hidden, [gestures componentsJoinedByString:@","]];
    for (UIView *child in view.subviews) LWDescribeStatusBarTouchView(child, depth + 1, output);
}

static void LWWriteStatusBarTouchMap(void) {
    UIWindow *window = LWStatusWindow;
    if (!window) return;
    NSMutableString *output = [NSMutableString stringWithFormat:@"window=%@ frame=%@ enabled=%d\n",
                               NSStringFromClass(window.class), NSStringFromCGRect(window.frame), window.userInteractionEnabled];
    LWDescribeStatusBarTouchView(window, 0, output);
    [output appendString:@"\n--- TOUCH SELECTORS ---\n"];
    for (Class cls = window.class; cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        [output appendFormat:@"[%@]\n", NSStringFromClass(cls)];
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            NSString *lower = name.lowercaseString;
            if ([lower containsString:@"touch"] || [lower containsString:@"event"] || [lower containsString:@"hit"] || [lower containsString:@"gesture"]) {
                [output appendFormat:@"- %@\n", name];
            }
        }
        free(methods);
    }
    LWTouchRuntimeMap = output;
    LWStartTouchRuntimeSocket();
}

static __attribute__((unused)) void LWStartRuntimeSocket(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int server = socket(AF_INET, SOCK_STREAM, 0);
        if (server < 0) return;
        struct sockaddr_in addr = {0};
        addr.sin_len = sizeof(addr);
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = htons(27043);
        int yes = 1;
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(server, 1) != 0) {
            close(server);
            return;
        }
        int client = accept(server, NULL, NULL);
        if (client >= 0) {
            while (!LWRuntimeMap) usleep(100000);
            NSData *data = [LWRuntimeMap dataUsingEncoding:NSUTF8StringEncoding];
            send(client, data.bytes, data.length, 0);
            close(client);
        }
        close(server);
    });
}

static void LWStartTouchRuntimeSocket(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int server = socket(AF_INET, SOCK_STREAM, 0);
        if (server < 0) return;
        struct sockaddr_in addr = {0};
        addr.sin_len = sizeof(addr);
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = htons(27044);
        int yes = 1;
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(server, 1) != 0) {
            close(server);
            return;
        }
        int client = accept(server, NULL, NULL);
        if (client >= 0) {
            NSData *data = [LWTouchRuntimeMap dataUsingEncoding:NSUTF8StringEncoding];
            send(client, data.bytes, data.length, 0);
            close(client);
        }
        close(server);
    });
}

static __attribute__((unused)) BOOL LWLooksLikeClockText(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length < 4 || text.length > 5) return NO;
    NSUInteger colon = [text rangeOfString:@":"].location;
    if (colon == NSNotFound || colon == 0 || colon + 1 >= text.length) return NO;
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    for (NSUInteger i = 0; i < text.length; i++) {
        if (i == colon) continue;
        if ([text characterAtIndex:i] > 127 || ![digits characterIsMember:[text characterAtIndex:i]]) return NO;
    }
    return YES;
}

static BOOL LWIsActualClockItem(UIView *item) {
    if (!item.window || item.hidden || item.alpha <= 0.01) return NO;
    id text = nil;
    @try { text = [item valueForKey:@"text"]; } @catch (__unused NSException *e) {}
    return LWLooksLikeClockText(text);
}

static id LWKVC(id object, NSString *key) {
    @try { return [object valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

static UIImage *LWApplicationIconForNotification(id bulletin, NSString *section) {
    if (!section.length) return nil;
    if (!LWNotificationIconCache) LWNotificationIconCache = [NSMutableDictionary dictionary];
    UIImage *cached = LWNotificationIconCache[section];
    if (cached) return cached;

    NSString *bundlePath = LWKVC(bulletin, @"sectionBundlePath");
    if (!bundlePath.length) {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        SEL workspaceSelector = NSSelectorFromString(@"defaultWorkspace");
        SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (workspaceClass && [workspaceClass respondsToSelector:workspaceSelector]) {
            id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, workspaceSelector);
            if ([workspace respondsToSelector:proxySelector]) {
                id proxy = ((id (*)(id, SEL, id))objc_msgSend)(workspace, proxySelector, section);
                NSURL *bundleURL = LWKVC(proxy, @"bundleURL");
                bundlePath = bundleURL.path;
            }
        }
    }
    if (!bundlePath.length) return nil;
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    NSDictionary *icons = bundle.infoDictionary[@"CFBundleIcons"];
    NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
    NSArray<NSString *> *names = primary[@"CFBundleIconFiles"];
    for (NSString *name in names.reverseObjectEnumerator) {
        NSString *base = [name stringByDeletingPathExtension];
        for (NSString *candidate in @[name, [base stringByAppendingString:@".png"], [base stringByAppendingString:@"@3x.png"], [base stringByAppendingString:@"@2x.png"]]) {
            NSString *path = [bundlePath stringByAppendingPathComponent:candidate];
            UIImage *image = [UIImage imageWithContentsOfFile:path];
            if (image) {
                LWNotificationIconCache[section] = image;
                return image;
            }
        }
    }
    return nil;
}

static void LWSetNativeRightStatusItemsHidden(UIView *view, UIWindow *window, BOOL hidden) {
    for (UIView *child in view.subviews) {
        NSString *name = NSStringFromClass(child.class);
        CGRect screenRect = [child convertRect:child.bounds toView:window];
        BOOL isRight = CGRectGetMidX(screenRect) > window.bounds.size.width * 0.72;
        BOOL isSystemIndicator = [name containsString:@"Cellular"] || [name containsString:@"Battery"] ||
            [name containsString:@"Wifi"] || [name containsString:@"WiFi"];
        if (isRight && isSystemIndicator) {
            if (hidden) {
                objc_setAssociatedObject(child, &LWNativeRightHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                child.hidden = YES;
            } else if ([objc_getAssociatedObject(child, &LWNativeRightHiddenKey) boolValue]) {
                child.hidden = NO;
                objc_setAssociatedObject(child, &LWNativeRightHiddenKey, nil, OBJC_ASSOCIATION_ASSIGN);
            }
        }
        LWSetNativeRightStatusItemsHidden(child, window, hidden);
    }
}

static void LWRenderNotificationTray(void) {
    NSArray<NSString *> *sections = [LWNotificationOrder subarrayWithRange:NSMakeRange(0, MIN(3, LWNotificationOrder.count))];
    UIView *anchor = LWNativeRightAnchor;
    UIWindow *window = anchor.window;
    UIView *host = anchor.superview;
    if (!window || !host) return;
    if (!sections.count) {
        LWNotificationTray.hidden = YES;
        LWSetNativeRightStatusItemsHidden(host, window, NO);
        return;
    }
    if (!LWNotificationTray) {
        LWNotificationTray = [[UIView alloc] initWithFrame:CGRectZero];
        LWNotificationTray.userInteractionEnabled = NO;
    }
    if (LWNotificationTray.superview != host) {
        [LWNotificationTray removeFromSuperview];
        [host addSubview:LWNotificationTray];
    }
    for (UIView *subview in LWNotificationTray.subviews) [subview removeFromSuperview];
    CGFloat iconSize = 16.0;
    CGFloat spacing = 4.0;
    CGFloat width = sections.count * iconSize + (sections.count - 1) * spacing;
    CGRect anchorFrame = [anchor convertRect:anchor.bounds toView:host];
    // The cellular item begins at the inner (notch-facing) edge of the
    // native right cluster.  Its right edge is therefore not the status
    // area's outer edge; align the notification group to that outer edge.
    CGFloat rightInset = 8.0;
    LWNotificationTray.frame = CGRectMake(host.bounds.size.width - width - rightInset,
                                          CGRectGetMidY(anchorFrame) - iconSize / 2.0,
                                          width, iconSize);
    LWNotificationTray.hidden = NO;
    for (NSUInteger i = 0; i < sections.count; i++) {
        NSDictionary *entry = LWNotificationRequests[sections[i]];
        UIImage *image = entry[@"image"];
        UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
        imageView.frame = CGRectMake(i * (iconSize + spacing), 0.0, iconSize, iconSize);
        imageView.contentMode = UIViewContentModeScaleAspectFill;
        imageView.layer.cornerRadius = 4.0;
        imageView.clipsToBounds = YES;
        [LWNotificationTray addSubview:imageView];
    }
    LWSetNativeRightStatusItemsHidden(host, window, YES);
    [host bringSubviewToFront:LWNotificationTray];
}

static NSTimeInterval LWNotificationTimestamp(id request) {
    id bulletin = LWKVC(request, @"bulletin");
    for (NSString *key in @[@"date", @"publicationDate", @"lastInterruptDate", @"timestamp"]) {
        id value = LWKVC(bulletin, key) ?: LWKVC(request, key);
        if ([value isKindOfClass:NSDate.class]) return [(NSDate *)value timeIntervalSince1970];
        if ([value respondsToSelector:@selector(doubleValue)]) {
            NSTimeInterval timestamp = [value doubleValue];
            if (timestamp > 0.0) return timestamp;
        }
    }
    return 0.0;
}

static void LWSortNotificationSectionsByLatestTimestamp(void) {
    [LWNotificationOrder sortUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        NSTimeInterval leftTime = [LWNotificationRequests[left][@"timestamp"] doubleValue];
        NSTimeInterval rightTime = [LWNotificationRequests[right][@"timestamp"] doubleValue];
        if (leftTime > rightTime) return NSOrderedAscending;
        if (leftTime < rightTime) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static void LWTrackNotificationRequest(id request, BOOL removed) {
    if (!request) return;
    if (!LWNotificationRequests) LWNotificationRequests = [NSMutableDictionary dictionary];
    if (!LWNotificationOrder) LWNotificationOrder = [NSMutableArray array];
    NSString *section = LWKVC(request, @"sectionIdentifier");
    if (![section isKindOfClass:NSString.class] || !section.length) return;
    if (removed) {
        [LWNotificationRequests removeObjectForKey:section];
        [LWNotificationOrder removeObject:section];
    } else {
        id bulletin = LWKVC(request, @"bulletin");
        id icon = LWKVC(bulletin, @"sectionIcon") ?: LWKVC(bulletin, @"icon");
        if (![icon isKindOfClass:UIImage.class]) icon = LWApplicationIconForNotification(bulletin, section);
        if (![icon isKindOfClass:UIImage.class]) return;
        NSTimeInterval timestamp = LWNotificationTimestamp(request);
        NSTimeInterval existingTimestamp = [LWNotificationRequests[section][@"timestamp"] doubleValue];
        // A section may contain several requests. Keep its most recent one,
        // rather than allowing a later scan of an older request to move it.
        if (!LWNotificationRequests[section] || timestamp >= existingTimestamp) {
            LWNotificationRequests[section] = @{ @"image": icon, @"timestamp": @(timestamp) };
        }
        if (![LWNotificationOrder containsObject:section]) [LWNotificationOrder addObject:section];
        LWSortNotificationSectionsByLatestTimestamp();
    }
    if (!LWReconcilingNotifications) {
        dispatch_async(dispatch_get_main_queue(), ^{ LWRenderNotificationTray(); });
    }
}

static void LWDescribeNotificationContainer(id object, NSMutableArray<NSString *> *debug) {
    if (!object) return;
    NSMutableSet<NSString *> *reported = [NSMutableSet set];
    for (Class cls = [object class]; cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            NSString *selector = NSStringFromSelector(method_getName(methods[i]));
            NSString *lower = selector.lowercaseString;
            if (([lower containsString:@"request"] || [lower containsString:@"notification"] || [lower containsString:@"section"] || [lower containsString:@"list"]) && ![reported containsObject:selector]) {
                [reported addObject:selector];
                [debug addObject:[NSString stringWithFormat:@"  selector %@", selector]];
            }
        }
        free(methods);
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(cls, &ivarCount);
        for (unsigned int i = 0; i < ivarCount; i++) {
            NSString *name = @(ivar_getName(ivars[i]));
            NSString *lower = name.lowercaseString;
            if ([lower containsString:@"request"] || [lower containsString:@"notification"] || [lower containsString:@"section"] || [lower containsString:@"list"]) {
                [debug addObject:[NSString stringWithFormat:@"  ivar %@", name]];
            }
        }
        free(ivars);
    }
}

static void LWLoadExistingNotificationRequests(id masterList) {
    if (!masterList) return;

    NSMutableArray *containers = [NSMutableArray array];

    // Prefer the section-backed path verified on iOS 17. Only fall back to
    // _visibleNotificationRequests when no section container is exposed.
    for (NSString *key in @[@"notificationSections", @"sections", @"_notificationSections"]) {
        id value = LWKVC(masterList, key);
        if (value) [containers addObject:value];
    }

    if (!containers.count) {
        SEL selector = NSSelectorFromString(@"_visibleNotificationRequests");
        if ([masterList respondsToSelector:selector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id requests = [masterList performSelector:selector];
#pragma clang diagnostic pop
            if (requests) [containers addObject:requests];
        }
    }

    NSMutableDictionary<NSString *, NSDictionary *> *previousRequests = LWNotificationRequests;
    NSMutableArray<NSString *> *previousOrder = LWNotificationOrder;

    LWNotificationRequests = [NSMutableDictionary dictionary];
    LWNotificationOrder = [NSMutableArray array];
    LWReconcilingNotifications = YES;

    BOOL authoritativeSnapshot = NO;

    for (id container in containers) {
        if (![container conformsToProtocol:@protocol(NSFastEnumeration)]) continue;

        NSArray *objects = nil;
        if ([container isKindOfClass:NSArray.class]) {
            objects = container;
        } else if ([container respondsToSelector:@selector(allObjects)]) {
            objects = [container allObjects];
        } else {
            NSMutableArray *collected = [NSMutableArray array];
            for (id object in container) {
                if (object) [collected addObject:object];
            }
            objects = collected;
        }

        if (objects.count == 0) authoritativeSnapshot = YES;

        for (id object in objects) {
            id bulletin = LWKVC(object, @"bulletin");
            if (bulletin) {
                authoritativeSnapshot = YES;
                LWTrackNotificationRequest(object, NO);
                continue;
            }

            for (NSString *key in @[@"allNotificationRequests",
                                    @"filteredNotificationRequests",
                                    @"notificationRequests",
                                    @"requests",
                                    @"visibleNotificationRequests",
                                    @"_visibleNotificationRequests"]) {
                id sectionRequests = LWKVC(object, key);
                if (![sectionRequests conformsToProtocol:@protocol(NSFastEnumeration)]) continue;

                authoritativeSnapshot = YES;

                if ([sectionRequests isKindOfClass:NSArray.class]) {
                    for (id request in sectionRequests) LWTrackNotificationRequest(request, NO);
                } else if ([sectionRequests respondsToSelector:@selector(allObjects)]) {
                    for (id request in [sectionRequests allObjects]) LWTrackNotificationRequest(request, NO);
                } else {
                    for (id request in sectionRequests) LWTrackNotificationRequest(request, NO);
                }

                if ([key isEqualToString:@"allNotificationRequests"]) break;
            }
        }
    }

    LWReconcilingNotifications = NO;

    if (!authoritativeSnapshot) {
        LWNotificationRequests = previousRequests ?: [NSMutableDictionary dictionary];
        LWNotificationOrder = previousOrder ?: [NSMutableArray array];
        return;
    }

    LWSortNotificationSectionsByLatestTimestamp();
    dispatch_async(dispatch_get_main_queue(), ^{
        LWRenderNotificationTray();
    });
}

static void LWRefreshNativeSignalBars(UIView *root) {
    if (!root) return;
    NSInteger detected = -1;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:root];
    while (pending.count && detected < 0) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if ([NSStringFromClass(view.class) containsString:@"STUIStatusBarCellularSignalView"]) {
            NSString *accessibility = [NSString stringWithFormat:@"%@ %@", view.accessibilityValue ?: @"", view.accessibilityLabel ?: @""];
            NSRegularExpression *digits = [NSRegularExpression regularExpressionWithPattern:@"(^|[^0-9])([0-4])([^0-9]|$)" options:0 error:nil];
            NSTextCheckingResult *match = [digits firstMatchInString:accessibility options:0 range:NSMakeRange(0, accessibility.length)];
            if (match.numberOfRanges > 2) detected = [[accessibility substringWithRange:[match rangeAtIndex:2]] integerValue];
            for (NSString *key in @[@"numberOfBars", @"signalBars", @"displayedBars", @"_numberOfBars", @"level"]) {
                if (detected >= 0) break;
                @try {
                    id value = [view valueForKey:key];
                    NSInteger bars = [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : -1;
                    if (bars >= 0 && bars <= 4) detected = bars;
                } @catch (__unused NSException *e) {}
            }
            if (detected < 0) {
                NSInteger layers = LWVisibleSignalLayers(view.layer);
                if (layers >= 0 && layers <= 4) detected = layers;
            }
        }
        [pending addObjectsFromArray:view.subviews];
    }
    if (detected >= 0) LWSignalBars = detected;
}

static __attribute__((unused)) void LWWriteRuntimeMap(void) {
    UIApplication *app = UIApplication.sharedApplication;
    NSMutableString *out = [NSMutableString stringWithFormat:@"app=%@ statusBar=%@\\n",
        NSStringFromClass(app.class), NSStringFromClass(app.statusBar.class)];
    [out appendFormat:@"statusBarFrame=%@ subviews=%lu\\n", NSStringFromCGRect(app.statusBar.frame), (unsigned long)app.statusBar.subviews.count];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            [out appendFormat:@"window=%@ frame=%@ root=%@\\n", NSStringFromClass(window.class), NSStringFromCGRect(window.frame), NSStringFromClass(window.rootViewController.class)];
        }
    }
    __block NSUInteger count = 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
    __block void (^dump)(UIView *, NSUInteger);
    dump = ^(UIView *view, NSUInteger depth) {
        if (!view || depth > 10 || count++ > 800) return;
        NSString *text = @"";
        if ([view isKindOfClass:UILabel.class]) text = ((UILabel *)view).text ?: @"";
        [out appendFormat:@"%@%@ frame=%@ text=%@ hidden=%d\\n",
            [@"  " stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
            NSStringFromClass(view.class), NSStringFromCGRect([view convertRect:view.bounds toView:nil]), text, view.hidden];
        for (UIView *child in [view.subviews copy]) dump(child, depth + 1);
    };
#pragma clang diagnostic pop
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) dump(window, 0);
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Library/Lilywhite" withIntermediateDirectories:YES attributes:nil error:nil];
    [out writeToFile:@"/var/mobile/Library/Lilywhite/StatusRuntime.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [out writeToFile:@"/var/root/LilywhiteStatusRuntime.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [out writeToFile:@"/var/jb/tmp/LilywhiteStatusRuntime.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [out writeToFile:@"/var/tmp/LilywhiteStatusRuntime.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [[NSUserDefaults standardUserDefaults] setObject:out forKey:@"LilywhiteStatusRuntime"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    LWRuntimeMap = [out copy];
}

static __attribute__((unused)) void LWHideNativeTimeItem(UIView *view, NSUInteger depth) {
    if (!view || depth > 8) return;
    if (view == (UIView *)LWCapsule) return;
    if (view != (UIView *)LWCapsule && [view isKindOfClass:UILabel.class] &&
        LWLooksLikeClockText(((UILabel *)view).text)) {
        LWNativeTimeView = view;
        if (LWStatusWindow) LWNativeTimeRect = [view convertRect:view.bounds toView:LWStatusWindow];
        LWNativeTimeHeight = CGRectGetHeight(view.frame);
        view.hidden = YES;
        return;
    }
    NSString *className = NSStringFromClass(view.class);
    NSString *identifier = view.accessibilityIdentifier ?: @"";
    NSString *label = view.accessibilityLabel ?: @"";
    NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@", className, identifier, label].lowercaseString;
    if ([haystack containsString:@"wifi"] || [haystack containsString:@"wireless"]) LWHasWiFi = YES;
    if ([className containsString:@"STUIStatusBarCellularSignalView"]) {
        // These are bar-count properties on different iOS releases. Avoid
        // signalStrength/strength: those often report the raw max (4).
        for (NSString *key in @[@"numberOfBars", @"signalBars", @"displayedBars", @"_numberOfBars", @"level"]) {
            @try {
                id value = [view valueForKey:key];
                if ([value respondsToSelector:@selector(integerValue)]) {
                    NSInteger n = [value integerValue];
                    if (n >= 0 && n <= 4) { LWSignalBars = n; break; }
                } 
            } @catch (__unused NSException *e) {}
        }
        // Some iOS versions expose no KVC property. Their native signal view
        // still creates one visible layer per bar, which is a reliable fallback.
        NSString *accessibility = [NSString stringWithFormat:@"%@ %@", view.accessibilityValue ?: @"", view.accessibilityLabel ?: @""];
        NSRegularExpression *digits = [NSRegularExpression regularExpressionWithPattern:@"(^|[^0-9])([0-4])([^0-9]|$)" options:0 error:nil];
        NSTextCheckingResult *match = [digits firstMatchInString:accessibility options:0 range:NSMakeRange(0, accessibility.length)];
        if (match && match.numberOfRanges > 2) LWSignalBars = [[accessibility substringWithRange:[match rangeAtIndex:2]] integerValue];
        if (LWSignalBars == 4) {
            NSInteger layers = LWVisibleSignalLayers(view.layer);
            if (layers > 0) LWSignalBars = layers;
        }
    }
    BOOL nativeLeftString = [className containsString:@"STUIStatusBarStringView"] &&
        CGRectGetMinX(view.frame) < 100.0 && CGRectGetWidth(view.frame) <= 100.0;
    // iOS 17 uses private UIStatusBar*Time* item views. Do not hide a broad
    // container; only hide a reasonably small leaf that identifies as time.
    if (([haystack containsString:@"time"] || nativeLeftString) && view != (UIView *)LWStatusBar &&
        view.bounds.size.width > 0.0 && view.bounds.size.width <= 110.0 &&
        view.subviews.count <= 3) {
        LWNativeTimeHeight = MAX(LWNativeTimeHeight, CGRectGetHeight(view.frame));
        LWNativeTimeView = view;
        if (LWStatusWindow) {
            LWNativeTimeRect = [view convertRect:view.bounds toView:LWStatusWindow];
        }
        view.hidden = YES;
        return;
    }
    for (UIView *child in [view.subviews copy]) {
        LWHideNativeTimeItem(child, depth + 1);
    }
}

static __attribute__((unused)) void LWHideViewsUnderCapsule(UIView *view, UIView *host, CGRect capsuleRect, NSUInteger depth) {
    if (!view || depth > 10 || view == (UIView *)LWCapsule) return;
    for (UIView *child in [view.subviews copy]) {
        if (child == (UIView *)LWCapsule) continue;
        CGRect r = [child convertRect:child.bounds toView:host];
        BOOL leaf = child.subviews.count <= 3;
        if (leaf && CGRectGetWidth(r) > 0.0 && CGRectIntersectsRect(r, capsuleRect) &&
            CGRectGetMinX(r) < CGRectGetMidX(capsuleRect)) {
            child.hidden = YES;
            continue;
        }
        LWHideViewsUnderCapsule(child, host, capsuleRect, depth + 1);
    }
}

static __attribute__((unused)) void LWInstallIntoStatusBar(UIStatusBar *statusBar) {
    if (!statusBar || statusBar.bounds.size.width <= 0.0) return;
    LWStatusBar = statusBar;
    UIWindow *hostWindow = statusBar.window;
    if (!hostWindow) return;
    LWStatusWindow = hostWindow;
    LWNativeTimeHeight = 0.0;
    LWNativeTimeRect = CGRectZero;
    LWNativeTimeView = nil;
    LWHasWiFi = NO;
    LWSignalBars = 4;
    LWHideNativeTimeItem(hostWindow, 0);
    UIView *nativeView = LWNativeTimeView;
    // Keep the replacement on the status-bar object itself. Its item
    // foreground subviews are rebuilt during app switches.
    UIView *host = (UIView *)statusBar;
    host.clipsToBounds = NO;
    CGFloat height = statusBar.bounds.size.height;
    // Reuse the native time item's complete geometry. This is the only
    // device-specific measurement that is guaranteed to stay outside the
    // notch on every iPhone size.
    BOOL hasNativeGeometry = !CGRectIsEmpty(LWNativeTimeRect) &&
        CGRectGetWidth(LWNativeTimeRect) > 0.0 && CGRectGetHeight(LWNativeTimeRect) > 0.0;
    // Reserve a small lower dock for the signal-hole without changing the
    // measured native left segment width.
    CGFloat capsuleHeight = hasNativeGeometry
        ? MIN(28.0, MAX(24.0, height - 22.0))
        : MIN(26.0, MAX(22.0, height - 28.0));
    if (LWCapsule.superview != host) {
        [LWCapsule removeFromSuperview];
        LWCapsule = [[LWStatusCapsule alloc] initWithFrame:CGRectZero];
        LWCapsule.accessibilityIdentifier = LWOverlayTag;
        LWCapsule.userInteractionEnabled = NO;
        [host addSubview:LWCapsule];
    }
    CGSize fittingSize = [LWCapsule sizeThatFits:CGSizeMake(statusBar.bounds.size.width, capsuleHeight)];
    // Keep the replacement entirely in the left segment before the notch.
    // Use the measured native time item's right edge as the real left-region
    // boundary. The extra 32pt is only the space needed for the Wi-Fi glyph.
    CGRect nativeInHost = nativeView ? [nativeView convertRect:nativeView.bounds toView:host] : CGRectZero;
    CGFloat originX = nativeView ? CGRectGetMinX(nativeInHost) - 2.0 : 8.0;
    CGFloat originY = nativeView ? MAX(0.0, CGRectGetMinY(nativeInHost) - 3.0) : 18.0;
    CGFloat width = hasNativeGeometry
        ? MIN(fittingSize.width, CGRectGetWidth(nativeInHost) + 4.0)
        : MIN(fittingSize.width, hostWindow.bounds.size.width * 0.27);
    if (!hasNativeGeometry) {
        originY = 18.0;
    }
    LWCapsule.frame = CGRectMake(originX, originY, width, capsuleHeight);
    LWCapsule.hidden = NO;
    [LWCapsule updateContent];
    [host bringSubviewToFront:LWCapsule];
}

%ctor {
#if LILYWHITE_DEBUG
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LWWriteNotificationRuntimeMap();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LWWriteStatusBarTouchMap();
    });
#endif
}

%hook UIStatusBar
- (void)didMoveToWindow {
    %orig;
}

- (void)layoutSubviews {
    %orig;
}
%end

// Use the native cellular item only as a layout anchor.  The notification
// tray becomes its sibling in the same STUI foreground hierarchy, exactly as
// the left capsule is a sibling of the native clock item.
static BOOL LWIsTemporaryRightStatusWindow(UIWindow *window) {
    if (!window) return NO;
    NSString *name = NSStringFromClass(window.class);
    return [name containsString:@"SBCoverSheetWindow"] ||
           [name containsString:@"SBControlCenterWindow"];
}

static void LWUpdateNativeRightAnchor(UIView *item) {
    UIWindow *window = item.window;
    if (!window || item.hidden) return;

    CGRect screenFrame = [item convertRect:item.bounds toView:window];
    if (CGRectGetMidX(screenFrame) < window.bounds.size.width * 0.72) return;

    UIView *newHost = item.superview;
    if (!newHost) return;

    if (LWNativeRightHost && LWNativeRightHost != newHost && LWNativeRightWindow) {
        if (LWIsTemporaryRightStatusWindow(window) &&
            !LWIsTemporaryRightStatusWindow(LWNativeRightWindow)) {
            LWPreviousRightAnchor = LWNativeRightAnchor;
            LWPreviousRightHost = LWNativeRightHost;
            LWPreviousRightWindow = LWNativeRightWindow;
        }

        LWSetNativeRightStatusItemsHidden(LWNativeRightHost,
                                          LWNativeRightWindow,
                                          NO);
    }

    LWNativeRightAnchor = item;
    LWNativeRightHost = newHost;
    LWNativeRightWindow = window;
    LWStatusWindow = window;
    LWRenderNotificationTray();
}

%hook STUIStatusBarCellularSignalView
- (void)willMoveToWindow:(UIWindow *)newWindow {
    UIView *item = (UIView *)(id)self;
    UIWindow *oldWindow = item.window;
    BOOL leavingTemporaryHost =
        (newWindow == nil &&
         item == LWNativeRightAnchor &&
         LWIsTemporaryRightStatusWindow(oldWindow));

    if (leavingTemporaryHost && LWNativeRightHost && oldWindow) {
        LWSetNativeRightStatusItemsHidden(LWNativeRightHost, oldWindow, NO);
    }

    %orig;

    if (leavingTemporaryHost) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *previousAnchor = LWPreviousRightAnchor;
            UIWindow *previousWindow = previousAnchor.window ?: LWPreviousRightWindow;
            UIView *previousHost = previousAnchor.superview ?: LWPreviousRightHost;

            if (previousAnchor && previousWindow && previousHost) {
                LWNativeRightAnchor = previousAnchor;
                LWNativeRightHost = previousHost;
                LWNativeRightWindow = previousWindow;
                LWStatusWindow = previousWindow;
                LWRenderNotificationTray();
            }

            LWPreviousRightAnchor = nil;
            LWPreviousRightHost = nil;
            LWPreviousRightWindow = nil;
        });
    }
}

- (void)didMoveToWindow {
    %orig;
    LWUpdateNativeRightAnchor((UIView *)(id)self);
}

- (void)layoutSubviews {
    %orig;
    LWUpdateNativeRightAnchor((UIView *)(id)self);
}
%end

// The clock is rebuilt as an STUIStatusBarStringView during app transitions,
// rotation and full-screen playback. Re-run replacement from the item's own
// lifecycle so a newly-created native clock can never leave Lilywhite behind.
%hook STUIStatusBarStringView
- (void)didMoveToWindow {
    %orig;
    UIView *item = (UIView *)(id)self;
#if LILYWHITE_DEBUG
    if (!LWNotificationMapCaptured) {
        LWNotificationMapCaptured = YES;
        LWWriteNotificationRuntimeMap();
        LWStartRuntimeSocket();
        NSArray<NSString *> *candidates = @[
            @"BBServer", @"SBBulletinBannerController", @"NCNotificationMasterList",
            @"NCNotificationListViewController", @"NCNotificationRequest",
            @"NCNotificationStructuredListViewController", @"BBBulletin"
        ];
        NSMutableArray<NSString *> *available = [NSMutableArray array];
        for (NSString *name in candidates) if (NSClassFromString(name)) [available addObject:name];
        NSLog(@"[Lilywhite] native status hook active; notification classes: %@", [available componentsJoinedByString:@", "]);
    }
#endif
    // The text is commonly still nil at this point. layoutSubviews below
    // performs the exact clock check after the system has configured it.
    if (!item.window) return;
    if (!LWIsActualClockItem(item)) return;
    LWStatusWindow = item.window;
    LWStatusCapsule *capsule = objc_getAssociatedObject(item, &LWNativeCapsuleKey);
    if (!capsule) {
        capsule = [[LWStatusCapsule alloc] initWithFrame:CGRectZero];
        capsule.userInteractionEnabled = YES;
        objc_setAssociatedObject(item, &LWNativeCapsuleKey, capsule, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [item.superview addSubview:capsule];
    }
    if ([item isKindOfClass:UILabel.class]) ((UILabel *)item).textColor = UIColor.clearColor;
    LWRefreshNativeSignalBars(item.window);
    UIView *host = item.superview;
    CGRect anchor = [item convertRect:item.bounds toView:host];
    CGFloat h = 20.0;
    capsule.frame = CGRectMake(CGRectGetMinX(anchor) - 2.0, CGRectGetMidY(anchor) - h / 2.0,
                               MIN(106.0, CGRectGetWidth(anchor) + 4.0), h);
    [host bringSubviewToFront:capsule];
    LWAttachNativeStatusBarAction(item, capsule);
    [capsule updateContent];
}

- (void)layoutSubviews {
    %orig;
    UIView *item = (UIView *)(id)self;
    if (!LWIsActualClockItem(item)) return;
    LWStatusWindow = item.window;
    LWStatusCapsule *capsule = objc_getAssociatedObject(item, &LWNativeCapsuleKey);
    if (!capsule) return;
    if ([item isKindOfClass:UILabel.class]) ((UILabel *)item).textColor = UIColor.clearColor;
    LWRefreshNativeSignalBars(item.window);
    UIView *host = item.superview;
    if (capsule.superview != host) [host addSubview:capsule];
    CGRect anchor = [item convertRect:item.bounds toView:host];
    CGFloat h = 20.0;
    capsule.frame = CGRectMake(CGRectGetMinX(anchor) - 2.0, CGRectGetMidY(anchor) - h / 2.0,
                               MIN(106.0, CGRectGetWidth(anchor) + 4.0), h);
    [host bringSubviewToFront:capsule];
    LWAttachNativeStatusBarAction(item, capsule);
    [capsule updateContent];
}
%end

%hook NCNotificationMasterList
- (id)init {
    id masterList = %orig;
    // The master list fills asynchronously after SpringBoard starts, so take
    // two snapshots to cover the initial and fully-loaded notification state.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LWLoadExistingNotificationRequests(masterList);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LWLoadExistingNotificationRequests(masterList);
    });
    return masterList;
}

- (void)setLoadedNotificationSections:(id)sections {
    %orig;
    LWLoadExistingNotificationRequests(self);
}

- (void)_notificationListDidChangeContent {
    %orig;
    LWLoadExistingNotificationRequests(self);
}

- (void)insertNotificationRequest:(id)request {
    %orig;
    LWTrackNotificationRequest(request, NO);
}

- (void)modifyNotificationRequest:(id)request {
    %orig;
    LWTrackNotificationRequest(request, NO);
}

- (void)removeNotificationRequest:(id)request {
    %orig;

    dispatch_async(dispatch_get_main_queue(), ^{
        LWLoadExistingNotificationRequests(self);
    });
}
%end

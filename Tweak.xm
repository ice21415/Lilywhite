#import <UIKit/UIKit.h>
#import <UIKit/UIApplication+Private.h>
#import <UIKit/UIStatusBar.h>
#import <objc/runtime.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

static NSString * const LWOverlayTag = @"com.user.lilywhite.overlay";
static BOOL LWHasWiFi;
static NSInteger LWSignalBars = 0;

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

    self.timeLabel = [self labelWithFont:[UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold]];
    self.signalLabel = [self labelWithFont:[UIFont systemFontOfSize:6.5 weight:UIFontWeightSemibold]];
    self.wifiImage = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"wifi"]];
    self.wifiImage.tintColor = UIColor.whiteColor;
    self.wifiImage.contentMode = UIViewContentModeScaleAspectFit;
    self.signalDock = [[UIView alloc] initWithFrame:CGRectZero];
    self.signalDock.backgroundColor = UIColor.clearColor;
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
    [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateContent) userInfo:nil repeats:YES];
    [self updateContent];
    return self;
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
    CGFloat dockWidth = MIN(28.0, self.bounds.size.width - 8.0);
    self.signalDock.frame = CGRectMake(MAX(4.0, (self.bounds.size.width - dockWidth) / 2.0),
                                       MAX(0.0, pillHeight - 10.0), dockWidth, 10.0);
    self.signalDock.layer.cornerRadius = 5.5;
    CGFloat wifiOffset = self.wifiImage.hidden ? 0.0 : 12.0;
    self.timeLabel.frame = CGRectMake(wifiOffset, 0.0, MAX(8.0, self.bounds.size.width - wifiOffset), MAX(20.0, pillHeight - 7.0));
    self.signalLabel.frame = self.signalDock.bounds;
    self.wifiImage.frame = CGRectMake(6.0, 3.0, 13.0, 13.0);
    CGRect outline = CGRectInset(self.pillView.bounds, 1.5, 1.5);
    self.batteryOutlineLayer.frame = self.pillView.bounds;
    self.batteryOutlineLayer.path = [UIBezierPath bezierPathWithRoundedRect:outline cornerRadius:CGRectGetHeight(outline) / 2.0].CGPath;
    // Remove a short segment from the bottom stroke. The signal dots occupy
    // this actual break in the outline rather than sitting inside a hole.
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.frame = self.pillView.bounds;
    mask.fillRule = kCAFillRuleEvenOdd;
    UIBezierPath *maskPath = [UIBezierPath bezierPathWithRect:self.pillView.bounds];
    CGFloat notchWidth = MIN(28.0, self.bounds.size.width - 8.0);
    [maskPath appendPath:[UIBezierPath bezierPathWithRect:CGRectMake((self.bounds.size.width - notchWidth) / 2.0,
                                                                       self.bounds.size.height - 8.0,
                                                                       notchWidth, 10.0)]];
    mask.path = maskPath.CGPath;
    self.batteryOutlineLayer.mask = mask;
    self.batteryOutlineLayer.strokeEnd = MIN(1.0, MAX(0.04, self.batteryFraction));
    BOOL charging = UIDevice.currentDevice.batteryState == UIDeviceBatteryStateCharging;
    UIColor *color = charging ? UIColor.systemGreenColor : (NSProcessInfo.processInfo.lowPowerModeEnabled ? UIColor.systemYellowColor : UIColor.whiteColor);
    self.batteryOutlineLayer.strokeColor = color.CGColor;
}

- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeMake(108.0, size.height);
}

- (void)updateContent {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm";
    self.timeLabel.text = [formatter stringFromDate:NSDate.date];

    // Do not instantiate CoreTelephony from SpringBoard. It is not needed for
    // the visual smoke test and keeps this build independent of its service
    // lifecycle during SpringBoard launch.
    NSMutableString *dots = [NSMutableString string];
    for (NSInteger i = 0; i < 4; i++) [dots appendString:(i < LWSignalBars ? @"●" : @"○")];
    self.signalLabel.text = dots;
    self.wifiImage.hidden = !LWHasWiFi;

    UIDevice *device = UIDevice.currentDevice;
    self.batteryFraction = device.batteryLevel >= 0.0 ? MIN(1.0, MAX(0.0, device.batteryLevel)) : 1.0;
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
static char LWNativeCapsuleKey;

static __attribute__((unused)) BOOL LWIsSpringBoardProcess(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
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
    // Native-item hooks below own installation. Do not create a window-level
    // overlay here: that was the source of the previous lifecycle mismatch.
}

%hook UIStatusBar
- (void)didMoveToWindow {
    %orig;
}

- (void)layoutSubviews {
    %orig;
}
%end

// The clock is rebuilt as an STUIStatusBarStringView during app transitions,
// rotation and full-screen playback. Re-run replacement from the item's own
// lifecycle so a newly-created native clock can never leave Lilywhite behind.
%hook STUIStatusBarStringView
- (void)didMoveToWindow {
    %orig;
    UIView *item = (UIView *)(id)self;
    // The text is commonly still nil at this point. layoutSubviews below
    // performs the exact clock check after the system has configured it.
    if (!item.window) return;
    if (!LWIsActualClockItem(item)) return;
    LWStatusCapsule *capsule = objc_getAssociatedObject(item, &LWNativeCapsuleKey);
    if (!capsule) {
        capsule = [[LWStatusCapsule alloc] initWithFrame:CGRectZero];
        capsule.userInteractionEnabled = NO;
        objc_setAssociatedObject(item, &LWNativeCapsuleKey, capsule, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [item.superview addSubview:capsule];
    }
    if ([item isKindOfClass:UILabel.class]) ((UILabel *)item).textColor = UIColor.clearColor;
    LWRefreshNativeSignalBars(item.window);
    UIView *host = item.superview;
    CGRect anchor = [item convertRect:item.bounds toView:host];
    CGFloat h = 24.0;
    capsule.frame = CGRectMake(CGRectGetMinX(anchor) - 2.0, CGRectGetMidY(anchor) - h / 2.0,
                               MIN(106.0, CGRectGetWidth(anchor) + 4.0), h);
    [host bringSubviewToFront:capsule];
    [capsule updateContent];
}

- (void)layoutSubviews {
    %orig;
    UIView *item = (UIView *)(id)self;
    if (!LWIsActualClockItem(item)) return;
    LWStatusCapsule *capsule = objc_getAssociatedObject(item, &LWNativeCapsuleKey);
    if (!capsule) return;
    if ([item isKindOfClass:UILabel.class]) ((UILabel *)item).textColor = UIColor.clearColor;
    LWRefreshNativeSignalBars(item.window);
    UIView *host = item.superview;
    if (capsule.superview != host) [host addSubview:capsule];
    CGRect anchor = [item convertRect:item.bounds toView:host];
    CGFloat h = 24.0;
    capsule.frame = CGRectMake(CGRectGetMinX(anchor) - 2.0, CGRectGetMidY(anchor) - h / 2.0,
                               MIN(106.0, CGRectGetWidth(anchor) + 4.0), h);
    [host bringSubviewToFront:capsule];
    [capsule updateContent];
}
%end

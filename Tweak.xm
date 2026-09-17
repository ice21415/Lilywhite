#import <UIKit/UIKit.h>
#import <UIKit/UIApplication+Private.h>
#import <UIKit/UIStatusBar.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

static NSString * const LWOverlayTag = @"com.user.lilywhite.overlay";

@interface LWStatusCapsule : UIView
@property(nonatomic, strong) UILabel *timeLabel;
@property(nonatomic, strong) UILabel *signalLabel;
@property(nonatomic, strong) UIImageView *wifiImage;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, assign) CGFloat batteryFraction;
@end

@implementation LWStatusCapsule

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.tag = 17012;
    self.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.86];
    self.layer.cornerRadius = 18.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
    self.clipsToBounds = YES;

    self.timeLabel = [self labelWithFont:[UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightSemibold]];
    self.signalLabel = [self labelWithFont:[UIFont systemFontOfSize:9 weight:UIFontWeightMedium]];
    self.wifiImage = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"wifi"]];
    self.wifiImage.tintColor = UIColor.whiteColor;
    self.wifiImage.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:self.timeLabel];
    [self addSubview:self.wifiImage];
    [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateContent) userInfo:nil repeats:YES];
    [self updateContent];
    return self;
}

- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];
    CGFloat inset = 1.5;
    CGRect outline = CGRectInset(self.bounds, inset, inset);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:outline cornerRadius:CGRectGetHeight(outline) / 2.0];
    [[UIColor colorWithWhite:1.0 alpha:(0.55 + 0.40 * self.batteryFraction)] setStroke];
    path.lineWidth = 1.8;
    [path stroke];
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
    self.timeLabel.frame = CGRectMake(10.0, 0.0, MAX(8.0, self.bounds.size.width - 40.0), h);
    self.wifiImage.frame = CGRectMake(MAX(8.0, self.bounds.size.width - 29.0), (h - 18.0) / 2.0, 18.0, 18.0);
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
    self.signalLabel.text = @"";

    UIDevice *device = UIDevice.currentDevice;
    self.batteryFraction = device.batteryLevel >= 0.0 ? MIN(1.0, MAX(0.0, device.batteryLevel)) : 1.0;
    [self setNeedsDisplay];
}

@end

static LWStatusCapsule *LWCapsule;
static __weak UIStatusBar *LWStatusBar;
static __weak UIWindow *LWStatusWindow;
static CGFloat LWNativeTimeHeight;
static CGRect LWNativeTimeRect;
static NSString *LWRuntimeMap;

static void LWStartRuntimeSocket(void) {
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

static BOOL LWLooksLikeClockText(NSString *text) {
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

static void LWWriteRuntimeMap(void) {
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

static void LWHideNativeTimeItem(UIView *view, NSUInteger depth) {
    if (!view || depth > 8) return;
    if (view != (UIView *)LWCapsule && [view isKindOfClass:UILabel.class] &&
        LWLooksLikeClockText(((UILabel *)view).text)) {
        if (LWStatusWindow) LWNativeTimeRect = [view convertRect:view.bounds toView:LWStatusWindow];
        LWNativeTimeHeight = CGRectGetHeight(view.frame);
        view.hidden = YES;
        return;
    }
    NSString *className = NSStringFromClass(view.class);
    NSString *identifier = view.accessibilityIdentifier ?: @"";
    NSString *label = view.accessibilityLabel ?: @"";
    NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@", className, identifier, label].lowercaseString;
    BOOL nativeLeftString = [className containsString:@"STUIStatusBarStringView"] &&
        CGRectGetMinX(view.frame) < 100.0 && CGRectGetWidth(view.frame) <= 100.0;
    // iOS 17 uses private UIStatusBar*Time* item views. Do not hide a broad
    // container; only hide a reasonably small leaf that identifies as time.
    if (([haystack containsString:@"time"] || nativeLeftString) && view != (UIView *)LWStatusBar &&
        view.bounds.size.width > 0.0 && view.bounds.size.width <= 110.0 &&
        view.subviews.count <= 3) {
        LWNativeTimeHeight = MAX(LWNativeTimeHeight, CGRectGetHeight(view.frame));
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

static void LWHideViewsUnderCapsule(UIView *view, UIView *host, CGRect capsuleRect, NSUInteger depth) {
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

static void LWInstallIntoStatusBar(UIStatusBar *statusBar) {
    if (!statusBar || statusBar.bounds.size.width <= 0.0) return;
    LWStatusBar = statusBar;
    UIWindow *hostWindow = statusBar.window;
    if (!hostWindow) return;
    LWStatusWindow = hostWindow;
    LWNativeTimeHeight = 0.0;
    LWNativeTimeRect = CGRectZero;
    LWHideNativeTimeItem(hostWindow, 0);
    CGFloat height = statusBar.bounds.size.height;
    // Reuse the native time item's complete geometry. This is the only
    // device-specific measurement that is guaranteed to stay outside the
    // notch on every iPhone size.
    BOOL hasNativeGeometry = !CGRectIsEmpty(LWNativeTimeRect) &&
        CGRectGetWidth(LWNativeTimeRect) > 0.0 && CGRectGetHeight(LWNativeTimeRect) > 0.0;
    CGFloat capsuleHeight = hasNativeGeometry
        ? MIN(38.0, MAX(34.0, height - 14.0))
        : MIN(24.0, MAX(18.0, height - 30.0));
    if (LWCapsule.superview != hostWindow) {
        [LWCapsule removeFromSuperview];
        LWCapsule = [[LWStatusCapsule alloc] initWithFrame:CGRectZero];
        LWCapsule.accessibilityIdentifier = LWOverlayTag;
        LWCapsule.userInteractionEnabled = NO;
        [hostWindow addSubview:LWCapsule];
    }
    CGSize fittingSize = [LWCapsule sizeThatFits:CGSizeMake(statusBar.bounds.size.width, capsuleHeight)];
    // Keep the replacement entirely in the left segment before the notch.
    // Use the measured native time item's right edge as the real left-region
    // boundary. The extra 32pt is only the space needed for the Wi-Fi glyph.
    CGRect barRect = [statusBar convertRect:statusBar.bounds toView:hostWindow];
    CGFloat originX = hasNativeGeometry ? CGRectGetMinX(LWNativeTimeRect) : 8.0;
    CGFloat originY = hasNativeGeometry ? CGRectGetMinY(barRect) + (CGRectGetHeight(barRect) - capsuleHeight) / 2.0 : 18.0;
    CGFloat width = hasNativeGeometry
        ? MIN(fittingSize.width, CGRectGetWidth(LWNativeTimeRect) + 18.0)
        : MIN(fittingSize.width, hostWindow.bounds.size.width * 0.27);
    if (!hasNativeGeometry) {
        originY = CGRectGetMinY(barRect) + MAX(0.0, (CGRectGetHeight(barRect) - capsuleHeight) / 2.0);
    }
    LWCapsule.frame = CGRectMake(originX, originY, width, capsuleHeight);
    LWHideViewsUnderCapsule(hostWindow, hostWindow, LWCapsule.frame, 0);
    [hostWindow bringSubviewToFront:LWCapsule];
}

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                LWInstallIntoStatusBar(UIApplication.sharedApplication.statusBar);
            });
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                LWInstallIntoStatusBar(UIApplication.sharedApplication.statusBar);
            });
        }];
        LWInstallIntoStatusBar(UIApplication.sharedApplication.statusBar);
        LWStartRuntimeSocket();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LWWriteRuntimeMap();
        });
    });
}

%hook UIStatusBar
- (void)didMoveToWindow {
    %orig;
    UIStatusBar *bar = self;
    // App switches can create a fresh status-bar instance after the active
    // notification has already fired. Install on the new instance itself.
    dispatch_async(dispatch_get_main_queue(), ^{
        LWInstallIntoStatusBar(bar);
    });
}

- (void)layoutSubviews {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        LWInstallIntoStatusBar(self);
    });
}
%end

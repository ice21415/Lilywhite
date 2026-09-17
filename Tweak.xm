#import <UIKit/UIKit.h>
#import <UIKit/UIApplication+Private.h>
#import <UIKit/UIStatusBar.h>

static NSString * const LWOverlayTag = @"com.user.lilywhite.overlay";

@interface LWStatusCapsule : UIView
@property(nonatomic, strong) UILabel *timeLabel;
@property(nonatomic, strong) UILabel *signalLabel;
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

    self.timeLabel = [self labelWithFont:[UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold]];
    self.signalLabel = [self labelWithFont:[UIFont systemFontOfSize:9 weight:UIFontWeightMedium]];
    [self addSubview:self.timeLabel];
    [self addSubview:self.signalLabel];
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
    [[UIColor colorWithWhite:1.0 alpha:0.92] setStroke];
    path.lineWidth = 1.8;
    [path stroke];
    CGFloat progressWidth = CGRectGetWidth(outline) * MIN(1.0, MAX(0.0, self.batteryFraction));
    if (progressWidth > 0.0) {
        UIBezierPath *progress = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(CGRectGetMinX(outline), CGRectGetMinY(outline), progressWidth, CGRectGetHeight(outline)) cornerRadius:CGRectGetHeight(outline) / 2.0];
        [[UIColor colorWithWhite:1.0 alpha:0.20] setFill];
        [progress fill];
    }
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
    self.timeLabel.frame = CGRectMake(5.0, 1.0, MAX(8.0, self.bounds.size.width - 10.0), MAX(16.0, h - 9.0));
    self.signalLabel.frame = CGRectMake(5.0, h - 10.0, MAX(8.0, self.bounds.size.width - 10.0), 9.0);
}

- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeMake(82.0, size.height);
}

- (void)updateContent {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm";
    self.timeLabel.text = [formatter stringFromDate:NSDate.date];

    // Do not instantiate CoreTelephony from SpringBoard. It is not needed for
    // the visual smoke test and keeps this build independent of its service
    // lifecycle during SpringBoard launch.
    self.signalLabel.text = @"▮▮▮ 5G";

    UIDevice *device = UIDevice.currentDevice;
    NSInteger percent = MAX(0, (NSInteger)round(device.batteryLevel * 100.0));
    self.batteryFraction = device.batteryLevel >= 0.0 ? MIN(1.0, MAX(0.0, device.batteryLevel)) : 1.0;
    [self setNeedsDisplay];
}

@end

static LWStatusCapsule *LWCapsule;
static __weak UIStatusBar *LWStatusBar;
static __weak UIWindow *LWStatusWindow;
static CGFloat LWNativeTimeHeight;

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
    [out writeToFile:@"/var/root/LilywhiteStatusRuntime.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void LWHideNativeTimeItem(UIView *view, NSUInteger depth) {
    if (!view || depth > 8) return;
    NSString *className = NSStringFromClass(view.class);
    NSString *identifier = view.accessibilityIdentifier ?: @"";
    NSString *label = view.accessibilityLabel ?: @"";
    NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@", className, identifier, label].lowercaseString;
    // iOS 17 uses private UIStatusBar*Time* item views. Do not hide a broad
    // container; only hide a reasonably small leaf that identifies as time.
    if ([haystack containsString:@"time"] && view != (UIView *)LWStatusBar &&
        view.bounds.size.width > 0.0 && view.bounds.size.width <= 110.0 &&
        view.subviews.count <= 3) {
        LWNativeTimeHeight = MAX(LWNativeTimeHeight, CGRectGetHeight(view.frame));
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
    LWHideNativeTimeItem(hostWindow, 0);
    CGFloat height = statusBar.bounds.size.height;
    // The status bar's bounds include the whole notch-safe region. The native
    // time item is the reliable measurement for the visible strip beside it.
    CGFloat capsuleHeight = LWNativeTimeHeight > 0.0
        ? MIN(24.0, MAX(18.0, LWNativeTimeHeight))
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
    CGFloat leftSegment = MIN(145.0, hostWindow.bounds.size.width * 0.30);
    CGFloat width = MIN(fittingSize.width, MAX(96.0, leftSegment - 8.0));
    CGRect barRect = [statusBar convertRect:statusBar.bounds toView:hostWindow];
    LWCapsule.frame = CGRectMake(8.0,
        CGRectGetMinY(barRect) + MAX(0.0, (CGRectGetHeight(barRect) - capsuleHeight) / 2.0), width, capsuleHeight);
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

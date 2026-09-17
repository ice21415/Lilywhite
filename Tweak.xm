#import <UIKit/UIKit.h>
#import <UIKit/UIApplication+Private.h>
#import <UIKit/UIStatusBar.h>

static NSString * const LWOverlayTag = @"com.user.lilywhite.overlay";

@interface LWStatusCapsule : UIView
@property(nonatomic, strong) UILabel *timeLabel;
@property(nonatomic, strong) UILabel *networkLabel;
@property(nonatomic, strong) UILabel *wifiLabel;
@property(nonatomic, strong) UILabel *batteryLabel;
@property(nonatomic, strong) NSTimer *timer;
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

    self.timeLabel = [self labelWithFont:[UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightSemibold]];
    self.networkLabel = [self labelWithFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]];
    self.wifiLabel = [self labelWithFont:[UIFont systemFontOfSize:13 weight:UIFontWeightMedium]];
    self.batteryLabel = [self labelWithFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]];
    [self addSubview:self.timeLabel];
    [self addSubview:self.networkLabel];
    [self addSubview:self.wifiLabel];
    [self addSubview:self.batteryLabel];
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
    CGFloat x = 10.0;
    NSArray<UILabel *> *labels = @[self.timeLabel, self.networkLabel, self.wifiLabel, self.batteryLabel];
    for (UILabel *label in labels) {
        CGFloat width = ceil([label sizeThatFits:CGSizeMake(CGFLOAT_MAX, h)].width);
        width = MAX(width, 12.0);
        label.frame = CGRectMake(x, 0.0, width, h);
        x += width + 6.0;
    }
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGFloat width = 20.0;
    for (UILabel *label in @[self.timeLabel, self.networkLabel, self.wifiLabel, self.batteryLabel]) {
        width += ceil([label sizeThatFits:CGSizeMake(CGFLOAT_MAX, size.height)].width) + 6.0;
    }
    return CGSizeMake(ceil(width), size.height);
}

- (void)updateContent {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm";
    self.timeLabel.text = [formatter stringFromDate:NSDate.date];

    // Do not instantiate CoreTelephony from SpringBoard. It is not needed for
    // the visual smoke test and keeps this build independent of its service
    // lifecycle during SpringBoard launch.
    self.networkLabel.text = @"—";
    self.wifiLabel.text = @"⌁";

    UIDevice *device = UIDevice.currentDevice;
    NSInteger percent = MAX(0, (NSInteger)round(device.batteryLevel * 100.0));
    self.batteryLabel.text = device.batteryState == UIDeviceBatteryStateCharging
        ? [NSString stringWithFormat:@"⚡%ld%%", (long)percent]
        : [NSString stringWithFormat:@"▣%ld%%", (long)percent];
}

@end

static LWStatusCapsule *LWCapsule;
static __weak UIStatusBar *LWStatusBar;
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

static void LWInstallIntoStatusBar(UIStatusBar *statusBar) {
    if (!statusBar || statusBar.bounds.size.width <= 0.0) return;
    LWStatusBar = statusBar;
    LWNativeTimeHeight = 0.0;
    LWHideNativeTimeItem(statusBar, 0);
    CGFloat height = statusBar.bounds.size.height;
    // The status bar's bounds include the whole notch-safe region. The native
    // time item is the reliable measurement for the visible strip beside it.
    CGFloat capsuleHeight = LWNativeTimeHeight > 0.0
        ? MIN(24.0, MAX(18.0, LWNativeTimeHeight))
        : MIN(24.0, MAX(18.0, height - 30.0));
    if (LWCapsule.superview != statusBar) {
        [LWCapsule removeFromSuperview];
        LWCapsule = [[LWStatusCapsule alloc] initWithFrame:CGRectZero];
        LWCapsule.accessibilityIdentifier = LWOverlayTag;
        LWCapsule.userInteractionEnabled = NO;
        [statusBar addSubview:LWCapsule];
    }
    CGSize fittingSize = [LWCapsule sizeThatFits:CGSizeMake(statusBar.bounds.size.width, capsuleHeight)];
    CGFloat width = MIN(fittingSize.width, MAX(120.0, statusBar.bounds.size.width - 16.0));
    LWCapsule.frame = CGRectMake(8.0, MAX(0.0, (height - capsuleHeight) / 2.0), width, capsuleHeight);
    [statusBar bringSubviewToFront:LWCapsule];
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

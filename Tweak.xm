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
    CGFloat x = 11.0;
    self.timeLabel.frame = CGRectMake(x, 0, 50, h);
    x += 55.0;
    self.networkLabel.frame = CGRectMake(x, 0, 28, h);
    x += 31.0;
    self.wifiLabel.frame = CGRectMake(x, 0, 25, h);
    x += 28.0;
    self.batteryLabel.frame = CGRectMake(x, 0, 43, h);
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
    LWHideNativeTimeItem(statusBar, 0);
    if (LWCapsule.superview == statusBar) {
        [statusBar bringSubviewToFront:LWCapsule];
        return;
    }
    [LWCapsule removeFromSuperview];
    CGFloat height = statusBar.bounds.size.height;
    CGFloat capsuleHeight = MIN(36.0, MAX(28.0, height - 6.0));
    LWCapsule = [[LWStatusCapsule alloc] initWithFrame:CGRectMake(8.0,
        MAX(0.0, (height - capsuleHeight) / 2.0), 177.0, capsuleHeight)];
    LWCapsule.accessibilityIdentifier = LWOverlayTag;
    LWCapsule.userInteractionEnabled = NO;
    [statusBar addSubview:LWCapsule];
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
    });
}

%hook UIStatusBar
- (void)layoutSubviews {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        LWInstallIntoStatusBar(self);
    });
}
%end

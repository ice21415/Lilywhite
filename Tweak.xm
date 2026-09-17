#import <UIKit/UIKit.h>

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

// SpringBoard owns several scene windows. Creating another UIWindow while its
// scene is still being assembled can make SpringBoard terminate during launch.
// Keep this first test build inside an existing SpringBoard window instead.
static LWStatusCapsule *LWCapsule;

static void LWLogNativeStatusBarCandidates(UIWindow *window) {
    NSMutableArray *pending = [NSMutableArray arrayWithObject:window];
    NSUInteger visited = 0;
    while (pending.count && visited < 400) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        visited++;
        NSString *name = NSStringFromClass(view.class);
        if ([name rangeOfString:@"statusbar" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            NSLog(@"[Lilywhite] candidate=%@ frame=%@ hidden=%d super=%@",
                  name, NSStringFromCGRect(view.frame), view.hidden,
                  NSStringFromClass(view.superview.class));
        }
        [pending addObjectsFromArray:view.subviews];
    }
    NSLog(@"[Lilywhite] candidate scan complete visited=%lu window=%@",
          (unsigned long)visited, NSStringFromClass(window.class));
}

static void LWInstall(void) {
    if (LWCapsule.superview) return;

    UIApplication *application = UIApplication.sharedApplication;
    UIWindow *hostWindow = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || !window.rootViewController) continue;
            hostWindow = window.isKeyWindow ? window : (hostWindow ?: window);
            if (window.isKeyWindow) break;
        }
        if (hostWindow.isKeyWindow) break;
    }

    if (!hostWindow || hostWindow.bounds.size.width <= 0.0) return;

    CGFloat top = MAX(hostWindow.safeAreaInsets.top, 20.0);
    LWCapsule = [[LWStatusCapsule alloc] initWithFrame:CGRectMake(8, top - 4, 177, 36)];
    LWCapsule.accessibilityIdentifier = LWOverlayTag;
    LWCapsule.userInteractionEnabled = NO;
    [hostWindow addSubview:LWCapsule];
    [hostWindow bringSubviewToFront:LWCapsule];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LWLogNativeStatusBarCandidates(hostWindow);
    });
}

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^installAfterLaunch)(NSNotification *) = ^(__unused NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                LWInstall();
            });
        };
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:installAfterLaunch];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:installAfterLaunch];
        LWInstall();
    });
}

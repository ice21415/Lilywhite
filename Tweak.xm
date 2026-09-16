#import <UIKit/UIKit.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>

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

    CTTelephonyNetworkInfo *info = [CTTelephonyNetworkInfo new];
    NSString *radio = info.serviceCurrentRadioAccessTechnology.allValues.firstObject;
    if ([radio containsString:@"NR"]) self.networkLabel.text = @"5G";
    else if ([radio containsString:@"LTE"]) self.networkLabel.text = @"LTE";
    else self.networkLabel.text = radio.length ? @"4G" : @"—";
    self.wifiLabel.text = @"⌁";

    UIDevice *device = UIDevice.currentDevice;
    NSInteger percent = MAX(0, (NSInteger)round(device.batteryLevel * 100.0));
    self.batteryLabel.text = device.batteryState == UIDeviceBatteryStateCharging
        ? [NSString stringWithFormat:@"⚡%ld%%", (long)percent]
        : [NSString stringWithFormat:@"▣%ld%%", (long)percent];
}

@end

static void LWHideNativeStatusBar(UIView *view) {
    for (UIView *child in [view.subviews copy]) {
        if (child.tag == 17012) continue;
        child.hidden = YES;
        LWHideNativeStatusBar(child);
    }
}

static void LWInstall(void) {
    UIApplication *application = UIApplication.sharedApplication;
    UIWindow *statusWindow = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSString *name = NSStringFromClass(window.class);
            if ([name.lowercaseString containsString:@"statusbar"]) {
                statusWindow = window;
                break;
            }
        }
        if (statusWindow) break;
    }
    if (!statusWindow) return;
    LWHideNativeStatusBar(statusWindow);
    if ([statusWindow viewWithTag:17012]) return;
    CGFloat top = statusWindow.safeAreaInsets.top > 0 ? statusWindow.safeAreaInsets.top : 20.0;
    LWStatusCapsule *capsule = [[LWStatusCapsule alloc] initWithFrame:CGRectMake(8, top - 4, 177, 36)];
    capsule.accessibilityIdentifier = LWOverlayTag;
    [statusWindow addSubview:capsule];
}

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                LWInstall();
            });
        }];
        LWInstall();
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *timer) {
            LWInstall();
        }];
    });
}

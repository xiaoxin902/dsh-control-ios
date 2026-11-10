// SPDX-License-Identifier: MIT
#import "RootViewController.h"

#import <dlfcn.h>

#import "DSHService.h"
#import "DSHWebViewController.h"

@interface RootViewController ()

@property (nonatomic, strong) UILabel *statusValueLabel;
@property (nonatomic, strong) UILabel *statusDetailLabel;
@property (nonatomic, strong) UISwitch *autoStartSwitch;
@property (nonatomic, strong) UILabel *autoStartHintLabel;
@property (nonatomic, strong) UIButton *openButton;
@property (nonatomic, strong) UIButton *startButton;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) UIButton *exportButton;

@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign, getter=isBusy) BOOL busy;
@property (nonatomic, copy, nullable) NSString *pendingCommand;
@property (nonatomic, assign) NSTimeInterval pendingSince;
@property (nonatomic, assign) NSUInteger commandGeneration;

@end

@implementation RootViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"DSH";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.ioQueue = dispatch_queue_create("bc.8848.dshcontrol.io", DISPATCH_QUEUE_SERIAL);

    [self buildInterface];
    [self reloadAutoStart];

    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(applicationDidBecomeActive:)
                                              name:UIApplicationDidBecomeActiveNotification
                                            object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(returnedFromHelper:)
                                              name:@"DSHReturnedFromHelperNotification"
                                            object:nil];
    if ([NSFileManager.defaultManager fileExistsAtPath:@"/tmp/dsh-selfcheck.on"]) {
        dispatch_async(self.ioQueue, ^{
            [DSHService runCapabilitySelfCheck];
        });
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:@"/tmp/dsh-launch-probe.on"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self runLaunchProbe];
        });
    }
    [self refreshStatus];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self startRefreshTimer];
    [self refreshStatus];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self logLayout];
}

- (void)logLayout {
    UISwitch *toSwitch = self.autoStartSwitch;
    UIButton *toStart = self.startButton;
    UIButton *toStop = self.stopButton;
    UIButton *toOpen = self.openButton;
    CGRect switchRect = [toSwitch convertRect:toSwitch.bounds toView:nil];
    CGRect startRect = [toStart convertRect:toStart.bounds toView:nil];
    CGRect stopRect = [toStop convertRect:toStop.bounds toView:nil];
    CGRect openRect = [toOpen convertRect:toOpen.bounds toView:nil];
    UIScrollView *scrollView = (UIScrollView *)self.openButton.superview.superview;
    CGFloat offset = [scrollView isKindOfClass:UIScrollView.class] ? scrollView.contentOffset.y : 0;
    DSHLog(@"layout: window=%@ scrollY=%.1f switch=%@ start=%@ stop=%@ open=%@",
           NSStringFromCGRect(self.view.window.bounds),
           offset,
           NSStringFromCGRect(switchRect),
           NSStringFromCGRect(startRect),
           NSStringFromCGRect(stopRect),
           NSStringFromCGRect(openRect));
    DSHLog(@"state: running=%d autostart=%d", self.running, [DSHService autoStartEnabled]);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopRefreshTimer];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [self startRefreshTimer];
    if (self.pendingCommand) {
        NSDictionary *result = [DSHService helperResultNewerThan:self.pendingSince];
        if (result) {
            [self finishHelperCommandWithResult:result];
            return;
        }
    }
    [self refreshStatus];
    [self logLayout];
}

- (void)startRefreshTimer {
    if (self.refreshTimer) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *__unused timer) {
        [weakSelf refreshStatus];
    }];
}

- (void)stopRefreshTimer {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

#pragma mark - Interface

- (void)buildInterface {
    UIScrollView *scrollView = [UIScrollView new];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:scrollView];

    UILabel *subtitleLabel = [self captionLabelWithText:[NSString stringWithFormat:@"DeepSeek Harness · 127.0.0.1:%u", (unsigned)DSHWebPort]];

    // Status card
    UILabel *statusTitleLabel = [UILabel new];
    statusTitleLabel.text = @"服务状态";
    statusTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    statusTitleLabel.adjustsFontForContentSizeCategory = YES;

    self.statusValueLabel = [UILabel new];
    self.statusValueLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.statusValueLabel.adjustsFontForContentSizeCategory = YES;
    self.statusValueLabel.textAlignment = NSTextAlignmentRight;
    self.statusValueLabel.text = @"检查中…";
    [self.statusValueLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                           forAxis:UILayoutConstraintAxisHorizontal];

    self.statusDetailLabel = [self captionLabelWithText:@"正在检测端口 3080"];

    UIStackView *statusTextStack = [[UIStackView alloc] initWithArrangedSubviews:@[ statusTitleLabel, self.statusDetailLabel ]];
    statusTextStack.axis = UILayoutConstraintAxisVertical;
    statusTextStack.spacing = 2;

    UIStackView *statusRow = [[UIStackView alloc] initWithArrangedSubviews:@[ statusTextStack, self.statusValueLabel ]];
    statusRow.axis = UILayoutConstraintAxisHorizontal;
    statusRow.alignment = UIStackViewAlignmentCenter;
    statusRow.spacing = 12;

    UIView *statusCard = [self cardWithArrangedSubviews:@[ statusRow ]];

    // Auto-start card
    UILabel *autoStartTitleLabel = [UILabel new];
    autoStartTitleLabel.text = @"开机自启";
    autoStartTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    autoStartTitleLabel.adjustsFontForContentSizeCategory = YES;

    self.autoStartSwitch = [UISwitch new];
    self.autoStartSwitch.accessibilityLabel = @"开机自启";
    [self.autoStartSwitch addTarget:self action:@selector(autoStartSwitchChanged:) forControlEvents:UIControlEventValueChanged];

    UIStackView *autoStartRow = [[UIStackView alloc] initWithArrangedSubviews:@[ autoStartTitleLabel, self.autoStartSwitch ]];
    autoStartRow.axis = UILayoutConstraintAxisHorizontal;
    autoStartRow.alignment = UIStackViewAlignmentCenter;
    autoStartRow.spacing = 12;

    self.autoStartHintLabel = [self captionLabelWithText:@""];
    UIView *autoStartCard = [self cardWithArrangedSubviews:@[ autoStartRow, self.autoStartHintLabel ]];

    // Main action
    self.openButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.openButton setTitle:@"打开 DeepSeek Harness" forState:UIControlStateNormal];
    self.openButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.openButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    [self.openButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.openButton.backgroundColor = UIColor.systemBlueColor;
    self.openButton.layer.cornerRadius = 14;
    self.openButton.layer.cornerCurve = kCACornerCurveContinuous;
    [self.openButton addTarget:self action:@selector(openTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.openButton.heightAnchor constraintEqualToConstant:56].active = YES;

    // Start / stop
    self.startButton = [self auxiliaryButtonWithTitle:@"启动" action:@selector(startTapped:)];
    self.stopButton = [self auxiliaryButtonWithTitle:@"停止" action:@selector(stopTapped:)];
    self.exportButton = [self auxiliaryButtonWithTitle:@"导出" action:@selector(exportTapped:)];

    UIStackView *auxRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.startButton, self.stopButton, self.exportButton
    ]];
    auxRow.axis = UILayoutConstraintAxisHorizontal;
    auxRow.distribution = UIStackViewDistributionFillEqually;
    auxRow.spacing = 12;

    UILabel *footerLabel = [self captionLabelWithText:[NSString stringWithFormat:@"版本 %s（%s）", APELIN_VERSION, APELIN_BUILD_ID]];
    footerLabel.textAlignment = NSTextAlignmentCenter;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        subtitleLabel, statusCard, autoStartCard, self.openButton, auxRow, footerLabel
    ]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 16;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [content setCustomSpacing:24 afterView:autoStartCard];
    [content setCustomSpacing:24 afterView:auxRow];
    [scrollView addSubview:content];

    UILayoutGuide *contentGuide = scrollView.contentLayoutGuide;
    UILayoutGuide *frameGuide = scrollView.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [content.topAnchor constraintEqualToAnchor:contentGuide.topAnchor constant:8],
        [content.bottomAnchor constraintEqualToAnchor:contentGuide.bottomAnchor constant:-28],
        [content.leadingAnchor constraintEqualToAnchor:contentGuide.leadingAnchor constant:20],
        [content.trailingAnchor constraintEqualToAnchor:contentGuide.trailingAnchor constant:-20],
        [content.widthAnchor constraintEqualToAnchor:frameGuide.widthAnchor constant:-40],
    ]];

    [self applyRunning:NO pid:0];
}

- (UILabel *)captionLabelWithText:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = UIColor.secondaryLabelColor;
    label.numberOfLines = 0;
    return label;
}

- (UIView *)cardWithArrangedSubviews:(NSArray<UIView *> *)views {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *card = [UIView new];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 14;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
    ]];
    return card;
}

- (UIButton *)auxiliaryButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButtonConfiguration *configuration = [UIButtonConfiguration tintedButtonConfiguration];
    configuration.title = title;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(12, 16, 12, 16);
    UIButton *button = [UIButton buttonWithConfiguration:configuration primaryAction:nil];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:48].active = YES;
    return button;
}

#pragma mark - State

- (void)applyRunning:(BOOL)running pid:(NSInteger)pid {
    self.running = running;
    self.statusValueLabel.text = running ? @"运行中" : @"未运行";
    self.statusValueLabel.textColor = running ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
    self.statusDetailLabel.text = running
        ? [NSString stringWithFormat:@"端口 3080 已连通 · PID %ld", (long)pid]
        : @"端口 3080 没有响应";
    // Both commands stay tappable: they are idempotent, and a disabled button
    // that the status guessed wrong is worse than a command that answers
    // "already running".
    self.startButton.enabled = YES;
    self.stopButton.enabled = YES;
    DSHLog(@"status applied: running=%d pid=%ld", running, (long)pid);
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    if (busy) {
        self.statusValueLabel.text = @"处理中…";
        self.statusValueLabel.textColor = UIColor.secondaryLabelColor;
        self.statusDetailLabel.text = @"正在执行命令，请稍候";
        self.openButton.enabled = NO;
    } else {
        self.openButton.enabled = YES;
    }
}

- (void)reloadAutoStart {
    BOOL enabled = [DSHService autoStartEnabled];
    [self.autoStartSwitch setOn:enabled animated:NO];
    self.autoStartHintLabel.text = enabled
        ? @"开启中：开机后 dsh 会自动启动。"
        : @"已关闭：开机后 dsh 不会自动启动（文件 autostart.off 存在）。";
}

- (void)refreshStatus {
    if (self.isBusy) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        BOOL running = [DSHService isRunning];
        NSInteger pid = running ? [DSHService currentPID] : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            RootViewController *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.isBusy) {
                return;
            }
            [strongSelf applyRunning:running pid:pid];
        });
    });
}

#pragma mark - Actions

- (void)autoStartSwitchChanged:(UISwitch *)sender {
    BOOL wanted = sender.isOn;
    NSError *error = nil;
    if (![DSHService setAutoStartEnabled:wanted error:&error]) {
        [sender setOn:!wanted animated:YES];
        DSHLog(@"autostart -> %d FAILED: %@", wanted, error.localizedDescription);
        [self showAlertWithTitle:@"设置开机自启失败" message:error.localizedDescription];
        return;
    }
    DSHLog(@"autostart -> %d ok, autostart.off exists=%d", wanted, !wanted);
    [self reloadAutoStart];
}

- (void)openTapped:(UIButton *)sender {
    if (self.isBusy) {
        return;
    }
    [self setBusy:YES];

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        // Right after 启动 the log can still be empty for a moment; give it a
        // few seconds instead of failing on the first tap.
        NSString *urlString = [DSHService currentTokenURL];
        BOOL serviceUp = [DSHService isRunning];
        if (urlString.length == 0 && serviceUp) {
            [DSHService requestFrontPage];
            urlString = [DSHService currentTokenURL];
        }
        for (int i = 0; i < 30 && urlString.length == 0 && serviceUp; i++) {
            usleep(500 * 1000);
            urlString = [DSHService currentTokenURL];
            serviceUp = [DSHService isRunning];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            RootViewController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            [strongSelf setBusy:NO];
            NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
            if (!url) {
                DSHLog(@"open: no token URL (serviceUp=%d)", serviceUp);
                [strongSelf showAlertWithTitle:@"没有找到访问地址"
                                       message:@"日志 /tmp/dsh-web.log 里还没有 dsh 的访问地址。\n请先点「启动」，等状态变成「运行中」再打开。"];
                return;
            }
            DSHLog(@"open: presenting %@", url.absoluteString);
            DSHWebViewController *browser = [[DSHWebViewController alloc] initWithURL:url];
            [strongSelf presentViewController:browser animated:YES completion:nil];
        });
    });
}

#pragma mark - Helper app

/// Immediate feedback the moment a command leaves the app.
- (void)showPendingCommand:(NSString *)command {
    BOOL stopping = [command isEqualToString:@"stop"];
    self.statusValueLabel.text = stopping ? @"正在停止…" : @"正在启动…";
    self.statusValueLabel.textColor = UIColor.secondaryLabelColor;
    self.statusDetailLabel.text = @"命令已发出";
}

/// After a start the port needs a few seconds; keep the screen in step instead
/// of leaving it on "未运行" until the user wonders whether the tap worked.
- (void)waitForServiceAfterStart:(NSUInteger)generation {
    [self setBusy:YES];
    self.statusValueLabel.text = @"启动中…";
    self.statusValueLabel.textColor = UIColor.secondaryLabelColor;
    self.statusDetailLabel.text = @"等待端口 3080 响应";

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        BOOL up = NO;
        for (int i = 0; i < 60; i++) {
            if ([DSHService isRunning]) {
                up = YES;
                break;
            }
            usleep(500 * 1000);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            RootViewController *strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.commandGeneration) {
                return;
            }
            [strongSelf setBusy:NO];
            [strongSelf refreshStatus];
            if (!up) {
                [strongSelf showAlertWithTitle:@"启动未完成"
                                       message:@"启动命令已执行，但 30 秒内端口 3080 仍未响应。\n请查看 /tmp/dsh-web.log。"];
            }
        });
    });
}

/// The daemon launchd starts on our request file: no window, no app switch.
- (void)runDaemonCommand:(NSString *)command generation:(NSUInteger)generation {
    [self setBusy:YES];
    NSTimeInterval since = NSDate.date.timeIntervalSince1970 - 0.5;

    if (![DSHService requestControlCommand:command]) {
        [self setBusy:NO];
        [self runHelperCommand:command];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        NSDictionary *result = nil;
        for (int i = 0; i < 24; i++) {
            result = [DSHService controlResultNewerThan:since];
            if (result) {
                break;
            }
            usleep(250 * 1000);
        }
        NSDictionary *finalResult = result ?: @{ @"ok": @NO, @"message": @"控制守护进程没有回应（超时）。" };
        dispatch_async(dispatch_get_main_queue(), ^{
            RootViewController *strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.commandGeneration) {
                return;
            }
            [strongSelf setBusy:NO];
            [strongSelf refreshStatus];
            [DSHService removeControlRequest];
            BOOL ok = [finalResult[@"ok"] boolValue];
            DSHLog(@"daemon: %@ -> ok=%d %@", command, ok, finalResult[@"message"] ?: @"");
            if (!ok && ![finalResult[@"message"] isEqualToString:@"already-running"]) {
                [strongSelf showAlertWithTitle:[command isEqualToString:@"stop"] ? @"停止未完成" : @"启动未完成"
                                       message:finalResult[@"message"] ?: @"未知错误"];
            }
            if ([command isEqualToString:@"start"]) {
                [strongSelf waitForServiceAfterStart:generation];
            }
        });
    });
}

/// The sandboxed app cannot run the launcher or signal dsh, so the work
/// happens in the bundled helper app: open its URL, then read the answer it
/// leaves in /tmp/dsh-helper.json.
- (void)runHelperCommand:(NSString *)command {
    if (self.isBusy) {
        return;
    }
    [self setBusy:YES];

    [DSHService removeHelperResult];
    self.pendingCommand = command;
    self.pendingSince = NSDate.date.timeIntervalSince1970 - 0.5;
    NSTimeInterval since = self.pendingSince;

    NSURL *url = [NSURL URLWithString:[@"dshhelper://" stringByAppendingString:command]];
    __weak typeof(self) weakSelf = self;
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
        DSHLog(@"helper: open %@ -> %d", url.absoluteString, success);
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                RootViewController *strongSelf = weakSelf;
                if (!strongSelf) {
                    return;
                }
                [strongSelf finishHelperCommandWithResult:@{ @"ok": @NO,
                                                             @"message": @"无法启动辅助应用（DSH 助手）。" }];
            });
        }
    }];

    dispatch_async(self.ioQueue, ^{
        NSDictionary *result = nil;
        for (int i = 0; i < 60; i++) {
            result = [DSHService helperResultNewerThan:since];
            if (result) {
                break;
            }
            usleep(500 * 1000);
        }
        NSDictionary *finalResult = result ?: @{ @"ok": @NO, @"message": @"辅助应用没有回应（超时）。" };
        dispatch_async(dispatch_get_main_queue(), ^{
            RootViewController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            [strongSelf finishHelperCommandWithResult:finalResult];
        });
    });
}

- (void)finishHelperCommandWithResult:(NSDictionary *)result {
    if (!self.pendingCommand) {
        [self refreshStatus];
        return;
    }
    NSString *command = self.pendingCommand;
    self.pendingCommand = nil;

    BOOL ok = [result[@"ok"] boolValue];
    NSString *message = result[@"message"];
    DSHLog(@"helper: %@ -> ok=%d %@", command, ok, message ?: @"");

    [self setBusy:NO];
    [self refreshStatus];
    if (!ok) {
        [self showAlertWithTitle:[command isEqualToString:@"stop"] ? @"停止未完成" : @"启动未完成"
                         message:message ?: @"未知错误"];
    }
}

/// dshcontrol://helper-done — the helper handing the user back.
- (void)returnedFromHelper:(NSNotification *)notification {
    if (self.pendingCommand) {
        NSDictionary *result = [DSHService helperResultNewerThan:self.pendingSince];
        if (result) {
            [self finishHelperCommandWithResult:result];
            return;
        }
    }
    [self refreshStatus];
}

- (void)startTapped:(UIButton *)sender {
    [self controlServiceWithCommand:@"start"];
}

- (void)stopTapped:(UIButton *)sender {
    [self controlServiceWithCommand:@"stop"];
}

/// Exports the newest dsh session to Markdown and opens the system share
/// sheet for it. The app's sandbox cannot see ~/.dsh, so the export itself
/// runs in our launchd daemon (which also knows how to run node22); the app
/// only reads the Markdown it leaves in Documents and shares it.
- (void)exportTapped:(UIButton *)sender {
    if (self.exportButton.enabled == NO) {
        return;
    }
    self.exportButton.enabled = NO;
    self.exportButton.alpha = 0.5;

    NSTimeInterval stamp = NSDate.date.timeIntervalSince1970;
    if (![DSHService requestControlCommand:@"export"]) {
        self.exportButton.enabled = YES;
        self.exportButton.alpha = 1.0;
        [self showAlertWithTitle:@"导出失败" message:@"无法写入请求文件：控制守护进程没有装好。"];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        NSDictionary *result = nil;
        for (int i = 0; i < 60; i++) {
            result = [DSHService controlResultNewerThan:stamp];
            if (result) {
                break;
            }
            usleep(500 * 1000);
        }
        [DSHService removeControlRequest];

        BOOL ok = [result[@"ok"] boolValue];
        NSString *path = @"/var/mobile/Documents/dsh-backup/exports/latest.md";
        BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:path];

        dispatch_async(dispatch_get_main_queue(), ^{
            RootViewController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            strongSelf.exportButton.enabled = YES;
            strongSelf.exportButton.alpha = 1.0;
            if (!ok || !exists) {
                NSString *why = result ? [result[@"message"] description] : @"控制守护进程没有回应";
                DSHLog(@"export failed: %@", why);
                [strongSelf showAlertWithTitle:@"导出失败" message:why];
                return;
            }
            DSHLog(@"export ok: %@", path);
            [strongSelf presentShareSheetForPath:path];
        });
    });
}

- (void)presentShareSheetForPath:(NSString *)path {
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *controller =
        [[UIActivityViewController alloc] initWithActivityItems:@[ url ] applicationActivities:nil];
    UIPopoverPresentationController *popover = controller.popoverPresentationController;
    if (popover) {
        popover.sourceView = self.exportButton;
        popover.sourceRect = self.exportButton.bounds;
    }
    [self presentViewController:controller animated:YES completion:nil];
}

/// Runs the command here when the sandbox lets an app spawn and signal
/// processes; when it does not, the same command goes to the helper app.
- (void)controlServiceWithCommand:(NSString *)command {
    // A new tap supersedes any command still waiting for its answer, so the
    // buttons never feel stuck behind an old one.
    self.commandGeneration += 1;
    NSUInteger generation = self.commandGeneration;
    [self setBusy:YES];
    [self showPendingCommand:command];

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        NSError *error = nil;
        BOOL ok = NO;

        if ([command isEqualToString:@"start"]) {
            if ([DSHService isRunning]) {
                ok = YES;
            } else if ([DSHService startWithError:&error]) {
                ok = YES;
                for (int i = 0; i < 40 && ![DSHService isRunning]; i++) {
                    usleep(500 * 1000);
                }
                if (![DSHService isRunning]) {
                    error = [NSError errorWithDomain:@"bc.8848.dshcontrol"
                                                code:ETIMEDOUT
                                            userInfo:@{ NSLocalizedDescriptionKey:
                                                            @"启动命令已经发出，但 20 秒内端口 3080 没有响应。\n可以稍后再看状态，或查看日志 /tmp/dsh-web.log。" }];
                    ok = NO;
                }
            }
        } else {
            ok = [DSHService stopWithError:&error];
        }

        BOOL blocked = !ok && (error.code == EPERM || error.code == EACCES || error.code == ENOEXEC);
        dispatch_async(dispatch_get_main_queue(), ^{
            RootViewController *strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.commandGeneration) {
                return;
            }
            [strongSelf setBusy:NO];
            if (blocked) {
                DSHLog(@"control: %@ blocked here (%@)", command, error.localizedDescription);
                if ([DSHService controlDaemonInstalled]) {
                    [strongSelf runDaemonCommand:command generation:generation];
                } else {
                    [strongSelf runHelperCommand:command];
                }
                return;
            }
            [strongSelf refreshStatus];
            if (!ok) {
                [strongSelf showAlertWithTitle:[command isEqualToString:@"stop"] ? @"停止未完成" : @"启动未完成"
                                       message:error.localizedDescription ?: @"未知错误"];
            }
        });
    });
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Launch probe

/// Diagnostic: which SpringBoard launch options keep the helper in the
/// background? Each candidate is tried and whether this app stayed active is
/// logged, so no screen watching is needed.
- (void)runLaunchProbe {
    void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    if (!handle) {
        DSHLog(@"probe: dlopen failed %s", dlerror());
        return;
    }
    typedef Boolean (*LaunchFn)(CFStringRef, CFURLRef, CFDictionaryRef, CFDictionaryRef, CFStringRef *);
    LaunchFn launch = (LaunchFn)dlsym(handle, "SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions");
    if (!launch) {
        DSHLog(@"probe: symbol SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions missing");
        dlclose(handle);
        return;
    }

    NSArray<NSString *> *keys = @[ @"SBSLaunchApplicationOptionLaunchInBackground",
                                   @"SBSLaunchInBackground",
                                   @"SBLaunchInBackground",
                                   @"LaunchInBackground" ];
    NSURL *url = [NSURL URLWithString:@"dshhelper://start"];
    for (NSString *key in keys) {
        CFStringRef launchError = NULL;
        NSDictionary *options = @{ key : @YES };
        Boolean started = launch(CFSTR("bc.8848.dshcontrol.helper"),
                                 (__bridge CFURLRef)url,
                                 (__bridge CFDictionaryRef)options,
                                 NULL,
                                 &launchError);
        DSHLog(@"probe: %@ -> %d error=%@", key, started,
               launchError ? (__bridge NSString *)launchError : @"(none)");
        sleep(2);
        DSHLog(@"probe: after %@ state=%ld (1=active,2=background)",
               key, (long)UIApplication.sharedApplication.applicationState);
    }
    dlclose(handle);
}

@end

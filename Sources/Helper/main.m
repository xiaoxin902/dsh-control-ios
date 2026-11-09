// SPDX-License-Identifier: MIT
//
// The helper app. LaunchServices starts it when the main app opens
// dshhelper://start or dshhelper://stop; it runs the dsh launcher or ends
// the dsh process, writes the outcome to /tmp/dsh-helper.json for the main
// app, hands the user back and exits. It shows no window of its own.
#import <UIKit/UIKit.h>

#import "DSHService.h"

@interface DSHHelperDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation DSHHelperDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSURL *url = launchOptions[UIApplicationLaunchOptionsURLKey];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self handleURL:url];
    });
    return YES;
}

- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    [self handleURL:url];
    return YES;
}

- (void)handleURL:(NSURL *)url {
    static BOOL handled = NO;
    if (handled) {
        return;
    }
    handled = YES;

    NSString *command = [url.scheme.lowercaseString isEqualToString:@"dshhelper"] ? url.host.lowercaseString : nil;
    DSHLog(@"helper app: command=%@", command);

    if (command.length == 0) {
        [self returnToMainApp];
        return;
    }

    NSDictionary *result = nil;
    if ([command isEqualToString:@"start"]) {
        NSError *error = nil;
        if ([DSHService isRunning]) {
            result = @{ @"ok": @YES, @"message": @"已经在运行" };
        } else if ([DSHService startWithError:&error]) {
            result = @{ @"ok": @YES, @"message": @"已发出启动命令" };
        } else {
            result = @{ @"ok": @NO, @"message": error.localizedDescription ?: @"启动失败" };
        }
    } else if ([command isEqualToString:@"stop"]) {
        NSError *error = nil;
        if ([DSHService stopWithError:&error]) {
            result = @{ @"ok": @YES, @"message": @"已停止" };
        } else {
            result = @{ @"ok": @NO, @"message": error.localizedDescription ?: @"停止失败" };
        }
    } else {
        result = @{ @"ok": @NO, @"message": [NSString stringWithFormat:@"未知命令 %@", command] };
    }

    [DSHService writeHelperResult:result command:command];
    [self returnToMainApp];
}

/// Hands the user back to the main app and ends this process.
- (void)returnToMainApp {
    NSURL *back = [NSURL URLWithString:@"dshcontrol://helper-done"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:back options:@{} completionHandler:^(BOOL success) {
            DSHLog(@"helper app: back to main app, success=%d", success);
            exit(0);
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(0);
        });
    });
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(DSHHelperDelegate.class));
    }
}

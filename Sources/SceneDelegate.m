// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
#import "SceneDelegate.h"
#import "RootViewController.h"

#import "DSHService.h"

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:UIWindowScene.class]) {
        return;
    }
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[RootViewController new]];
    navigation.navigationBar.prefersLargeTitles = YES;
    self.window.rootViewController = navigation;
    [self.window makeKeyAndVisible];
}

/// dshcontrol://helper-done comes back from the helper app after a start or
/// stop, so the main screen can pick up the outcome.
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    for (UIOpenURLContext *context in URLContexts) {
        DSHLog(@"open url: %@", context.URL.absoluteString);
    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"DSHReturnedFromHelperNotification" object:nil];
}

@end

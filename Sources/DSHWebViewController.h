// SPDX-License-Identifier: MIT
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Full-screen web view for the dsh UI: no address bar, no browser chrome,
/// only a close button above the page. Before any page script runs it
/// installs a small shim for the JavaScript APIs that dsh uses but older
/// WebKit (iOS 16, iOS 17.2 and below) does not have.
@interface DSHWebViewController : UIViewController

- (instancetype)initWithURL:(NSURL *)url NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

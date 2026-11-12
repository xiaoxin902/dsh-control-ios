// SPDX-License-Identifier: MIT
//
// Everything the app does to the DeepSeek Harness install that already
// lives on this device: probe the web port, read the token URL out of the
// log, switch auto-start on and off, start the launcher script and stop
// the process named in the pid file.
//
// Only the user's own dsh files are touched, all below
// /var/mobile/Documents/dsh; nothing under the bootstrap is read or
// written. Every method but +isRunning blocks, so call them off the main
// thread.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// /var/mobile/Documents/dsh, the install folder.
FOUNDATION_EXPORT NSString *const DSHDirectoryPath;
/// /tmp/dsh-web.log, the file dsh writes its access URL into.
FOUNDATION_EXPORT NSString *const DSHLogPath;
/// The port dsh listens on, 3080.
FOUNDATION_EXPORT const uint16_t DSHWebPort;

/// A diagnostic line: appended to /tmp/dsh-control.log and sent to os_log
/// as subsystem bc.8848.dshcontrol, so what the app did can be read back
/// afterwards.
FOUNDATION_EXPORT void DSHLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

@interface DSHService : NSObject

/// YES when a TCP connection to 127.0.0.1:3080 is accepted. Fast: the
/// connect is non-blocking with a short timeout.
+ (BOOL)isRunning;

/// The newest http://127.0.0.1:3080/?token=… in the log, or nil.
+ (nullable NSString *)currentTokenURL;

/// Makes one HTTP request to the web server: it only prints its token URL
/// into the log after the first HTTP connection, so a bare TCP probe leaves
/// the log without one.
+ (void)requestFrontPage;

/// The pid dsh-web.pid names, 0 when the file is missing or unreadable.
+ (NSInteger)currentPID;

/// YES unless /var/mobile/Documents/dsh/autostart.off exists.
+ (BOOL)autoStartEnabled;

/// Creates or deletes autostart.off. NO and an NSError on failure.
+ (BOOL)setAutoStartEnabled:(BOOL)enabled error:(NSError *_Nullable *_Nullable)error;

/// Runs the user's launcher script detached. NO and an NSError when it
/// could not be spawned at all.
+ (BOOL)startWithError:(NSError *_Nullable *_Nullable)error;

/// SIGTERMs the pid in dsh-web.pid and waits for the port to close.
/// Blocks up to a few seconds; returns NO with an NSError when there was
/// no pid or the signal did not stop the process.
+ (BOOL)stopWithError:(NSError *_Nullable *_Nullable)error;

/// Deletes a pid file whose process is gone, so the next start is clean.
+ (void)removeStalePIDFile;

/// Diagnostic: what this build may do — executable checks, a spawn attempt and
/// whether signalling another process is allowed. Runs only when the caller
/// asks for it, and logs to /tmp/dsh-control.log.
+ (void)runCapabilitySelfCheck;

/// Where the helper app leaves its answer for the main app.
FOUNDATION_EXPORT NSString *const DSHHelperResultPath;

/// The request and answer files of the LaunchDaemon that does start/stop.
FOUNDATION_EXPORT NSString *const DSHControlRequestPath;
FOUNDATION_EXPORT NSString *const DSHControlResultPath;

/// YES when this package's control daemon is installed and loaded by launchd.
+ (BOOL)controlDaemonInstalled;
/// Writes the request file that wakes the daemon. NO when it cannot be written.
+ (BOOL)requestControlCommand:(NSString *)command;
/// The daemon's answer, only when it is newer than `timestamp`.
+ (nullable NSDictionary *)controlResultNewerThan:(NSTimeInterval)timestamp;
/// Deletes the request file once its answer has been read.
+ (void)removeControlRequest;

/// The helper app side: reports what it did.
+ (BOOL)writeHelperResult:(NSDictionary *)result command:(NSString *)command;
/// The main app side: the answer, only when it is newer than `timestamp`.
+ (nullable NSDictionary *)helperResultNewerThan:(NSTimeInterval)timestamp;
+ (void)removeHelperResult;

@end

NS_ASSUME_NONNULL_END

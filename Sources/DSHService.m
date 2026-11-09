// SPDX-License-Identifier: MIT
#import "DSHService.h"

#import "DSHConfig.h"

#import "ApelinBootstrap.h"

#import <errno.h>
#import <fcntl.h>
#import <mach/mach.h>
#import <mach/task.h>
#import <os/log.h>
#import <signal.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <netinet/in.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

NSString *const DSHDirectoryPath = @"/var/mobile/Documents/dsh";
NSString *const DSHLogPath = @"/tmp/dsh-web.log";
const uint16_t DSHWebPort = 3080;
NSString *const DSHHelperResultPath = @"/tmp/dsh-helper.json";
NSString *const DSHControlRequestPath = @"/var/mobile/Documents/dsh/.dshcontrol-request";
NSString *const DSHControlResultPath = @"/var/mobile/Documents/dsh/.dshcontrol-result";

static NSString *const DSHLauncherName = @"dsh";
static NSString *const DSHPIDFileName = @"dsh-web.pid";
static NSString *const DSHOffFileName = @"autostart.off";
static NSString *const DSHAppLogPath = @"/tmp/dsh-control.log";

void DSHLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [formatter stringFromDate:NSDate.date], message];

    static os_log_t logger;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = os_log_create("bc.8848.dshcontrol", "app");
    });
    os_log(logger, "%{public}@", line);

    static NSLock *lock;
    static dispatch_once_t lockOnce;
    dispatch_once(&lockOnce, ^{
        lock = [NSLock new];
    });
    [lock lock];
    FILE *file = fopen(DSHAppLogPath.fileSystemRepresentation, "a");
    if (file) {
        fputs(line.UTF8String, file);
        fclose(file);
    }
    [lock unlock];
}

static NSError *DSHMakeError(int code, NSString *what) {
    NSString *reason = [NSString stringWithUTF8String:strerror(code)];
    NSString *message = [NSString stringWithFormat:@"%@（%@，errno %d）", what, reason ?: @"未知错误", code];
    return [NSError errorWithDomain:@"bc.8848.dshcontrol"
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}

static NSString *DSHPathForFileName(NSString *name) {
    return [DSHDirectoryPath stringByAppendingPathComponent:name];
}

extern kern_return_t task_for_pid(mach_port_t target_tport, int pid, mach_port_t *t);

/// Ends a process through a task port; 0 when it was ended, a Mach error
/// code otherwise. Needs task_for_pid-allow in the app's signature.
static kern_return_t DSHTerminateTaskForPID(int pid) {
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t result = task_for_pid(mach_task_self(), pid, &task);
    if (result != KERN_SUCCESS) {
        return result;
    }
    result = task_terminate(task);
    mach_port_deallocate(mach_task_self(), task);
    return result;
}

/// Non-blocking connect with a short timeout, so a wedged port cannot
/// hang the caller.
static BOOL DSHConnectSucceeds(uint16_t port, NSTimeInterval timeout) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return NO;
    }
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    BOOL reachable = NO;
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        reachable = YES;
    } else if (errno == EINPROGRESS) {
        fd_set writeSet;
        FD_ZERO(&writeSet);
        FD_SET(fd, &writeSet);
        struct timeval tv;
        tv.tv_sec = (time_t)timeout;
        tv.tv_usec = (suseconds_t)((timeout - (NSTimeInterval)tv.tv_sec) * 1000000.0);
        if (select(fd + 1, NULL, &writeSet, NULL, &tv) > 0) {
            int socketError = 0;
            socklen_t length = sizeof(socketError);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 && socketError == 0) {
                reachable = YES;
            }
        }
    }
    close(fd);
    return reachable;
}

@implementation DSHService

+ (BOOL)isRunning {
    return DSHConnectSucceeds(DSHWebPort, 0.4);
}

+ (NSString *)currentTokenURL {
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:@"http://127\\.0\\.0\\.1:3080/\\?token=[A-Za-z0-9_-]+"
                                                              options:0
                                                                error:NULL];
    });

    NSData *data = [NSData dataWithContentsOfFile:DSHLogPath];
    if (data.length == 0) {
        // /tmp is a symlink on iOS; the real file is under /private/var.
        data = [NSData dataWithContentsOfFile:@"/private/var/tmp/dsh-web.log"];
    }
    if (data.length == 0) {
        NSError *error = nil;
        [NSData dataWithContentsOfFile:DSHLogPath options:0 error:&error];
        DSHLog(@"token: cannot read %@ (%@)", DSHLogPath, error.localizedDescription ?: @"unknown");
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length == 0) {
        return nil;
    }
    NSArray<NSTextCheckingResult *> *matches = [expression matchesInString:text
                                                                  options:0
                                                                    range:NSMakeRange(0, text.length)];
    NSTextCheckingResult *last = matches.lastObject;
    if (!last) {
        return nil;
    }
    return [text substringWithRange:last.range];
}

+ (void)requestFrontPage {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return;
    }
    struct timeval timeout;
    timeout.tv_sec = 2;
    timeout.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(DSHWebPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        const char *request = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
        if (write(fd, request, strlen(request)) > 0) {
            char buffer[256];
            (void)read(fd, buffer, sizeof(buffer));
        }
        DSHLog(@"token: poked the web server so it prints its address");
    }
    close(fd);
}

+ (NSInteger)currentPID {
    NSString *text = [NSString stringWithContentsOfFile:DSHPathForFileName(DSHPIDFileName)
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (text.length == 0) {
        return 0;
    }
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSInteger pid = trimmed.integerValue;
    return pid > 0 ? pid : 0;
}

+ (BOOL)autoStartEnabled {
    return ![[NSFileManager defaultManager] fileExistsAtPath:DSHPathForFileName(DSHOffFileName)];
}

+ (BOOL)setAutoStartEnabled:(BOOL)enabled error:(NSError **)error {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *offPath = DSHPathForFileName(DSHOffFileName);

    if (![manager fileExistsAtPath:DSHDirectoryPath]) {
        if (error) {
            *error = DSHMakeError(ENOENT, @"找不到 dsh 目录 /var/mobile/Documents/dsh");
        }
        return NO;
    }

    if (enabled) {
        if (![manager fileExistsAtPath:offPath]) {
            return YES;
        }
        NSError *removeError = nil;
        if (![manager removeItemAtPath:offPath error:&removeError]) {
            if (error) {
                *error = removeError;
            }
            return NO;
        }
        return YES;
    }

    NSString *note = @"由 DSH 应用创建：这个文件存在时，开机不会自动启动 DeepSeek Harness。\n";
    NSError *writeError = nil;
    if (![note writeToFile:offPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
        if (error) {
            *error = writeError;
        }
        return NO;
    }
    return YES;
}

+ (BOOL)startWithError:(NSError **)error {
    NSString *launcher = DSHPathForFileName(DSHLauncherName);
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager fileExistsAtPath:launcher]) {
        if (error) {
            *error = DSHMakeError(ENOENT, @"找不到启动脚本：/var/mobile/Documents/dsh/dsh");
        }
        return NO;
    }
    DSHLog(@"start: executable check=%d", [manager isExecutableFileAtPath:launcher]);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    // The wrapper prints only progress; keep it out of the app's stdout
    // and let it end on its own.
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    // ARC: the UTF8String pointers must outlive posix_spawn, so the strings
    // they come from are held in locals until the function returns.
    NSString *pathEnv = [@"PATH=" stringByAppendingString:DSHConfigSearchPath()];
    NSString *tmpEnv = [@"TMPDIR=" stringByAppendingString:DSHConfigTmpDirectory()];
    char *envp[] = {
        "HOME=/var/mobile",
        (char *)pathEnv.UTF8String,
        (char *)tmpEnv.UTF8String,
        NULL
    };
    const char *script = launcher.fileSystemRepresentation;
    pid_t pid = 0;
    int result = -1;

    // The script's #!/bin/sh names a path iOS itself does not have: the
    // shell lives in the bootstrap, so run it through that shell. Spawning
    // the script directly only works where the shebang resolves.
    NSString *shell = [self bootstrapShellPath];
    if (shell) {
        const char *shellPath = shell.fileSystemRepresentation;
        char *argv[] = { (char *)shellPath, (char *)script, NULL };
        result = posix_spawn(&pid, shellPath, &actions, NULL, argv, envp);
        DSHLog(@"start: %@ %@ -> %d", shell, launcher, result);
    }
    if (result != 0) {
        char *argv[] = { (char *)script, NULL };
        result = posix_spawn(&pid, script, &actions, NULL, argv, envp);
        DSHLog(@"start: direct %@ -> %d", launcher, result);
    }
    posix_spawn_file_actions_destroy(&actions);

    if (result != 0) {
        DSHLog(@"start failed: %s", strerror(result));
        if (error) {
            *error = DSHMakeError(result, @"无法启动 dsh");
        }
        return NO;
    }
    DSHLog(@"start: spawned pid %d", (int)pid);
    return YES;
}

/// The bootstrap's shell, nil when none of the candidates can be executed.
+ (nullable NSString *)bootstrapShellPath {
    NSArray<NSString *> *candidates = @[
        ApelinBootstrapPath(@"/bin/sh") ?: @"",
        ApelinBootstrapPath(@"/usr/bin/dash") ?: @"",
    ];
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *candidate in candidates) {
        if (candidate.length > 0 && [manager isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

+ (BOOL)stopWithError:(NSError **)error {
    NSInteger pid = [self currentPID];
    if (pid <= 0) {
        if (error) {
            *error = DSHMakeError(ENOENT, @"找不到 dsh-web.pid，不知道要停止哪个进程");
        }
        return NO;
    }
    if (kill((pid_t)pid, 0) != 0 && errno == ESRCH) {
        [self removeStalePIDFile];
        if (error) {
            *error = DSHMakeError(ESRCH, [NSString stringWithFormat:@"进程 %ld 已经退出，PID 文件是旧的", (long)pid]);
        }
        return NO;
    }
    if (kill((pid_t)pid, SIGTERM) != 0) {
        int code = errno;
        DSHLog(@"stop: kill(%ld) failed: %s", (long)pid, strerror(code));
        // A sandboxed app may not signal another process, but a task port
        // obtained by entitlement can still end it.
        kern_return_t terminated = DSHTerminateTaskForPID((int)pid);
        DSHLog(@"stop: task terminate for %ld -> %d", (long)pid, terminated);
        if (terminated != 0) {
            if (error) {
                *error = DSHMakeError(code, [NSString stringWithFormat:@"无法结束进程 %ld", (long)pid]);
            }
            return NO;
        }
    }

    // Give it a moment to let go of the port; a stuck process gets removed
    // the hard way, as it would never come back otherwise.
    for (int i = 0; i < 24; i++) {
        if (![self isRunning]) {
            [self removePIDFileForPID:pid];
            DSHLog(@"stop: pid %ld stopped after SIGTERM", (long)pid);
            return YES;
        }
        usleep(250 * 1000);
    }
    if (kill((pid_t)pid, SIGKILL) != 0 && errno != ESRCH) {
        int code = errno;
        if (error) {
            *error = DSHMakeError(code, [NSString stringWithFormat:@"进程 %ld 没有响应，也杀不掉", (long)pid]);
        }
        return NO;
    }
    for (int i = 0; i < 12; i++) {
        if (![self isRunning]) {
            [self removePIDFileForPID:pid];
            DSHLog(@"stop: pid %ld killed after SIGKILL", (long)pid);
            return YES;
        }
        usleep(250 * 1000);
    }
    if (error) {
        *error = DSHMakeError(ETIMEDOUT, @"进程已经结束，但端口 3080 仍然被占用");
    }
    return NO;
}

+ (void)removePIDFileForPID:(NSInteger)pid {
    // Only when the file still names the process just stopped: a fresh
    // start may have written its own pid in the meantime.
    if ([self currentPID] == pid) {
        [[NSFileManager defaultManager] removeItemAtPath:DSHPathForFileName(DSHPIDFileName) error:NULL];
    }
}

+ (void)removeStalePIDFile {
    NSInteger pid = [self currentPID];
    if (pid > 0 && kill((pid_t)pid, 0) == 0) {
        return;
    }
    [[NSFileManager defaultManager] removeItemAtPath:DSHPathForFileName(DSHPIDFileName) error:NULL];
}

+ (NSString *)exportLatestSessionWithError:(NSError **)error {
    NSFileManager *manager = NSFileManager.defaultManager;
    // The app is sandboxed for its own container plus the user's Documents
    // folder: ~/.dsh (a dot directory directly under /var/mobile) is
    // invisible to it, so the bootstrap copy the package installs is the one
    // that matters. The others are fallbacks for hand-made installs.
    NSString *bootstrapCopy = ApelinBootstrapPath(@"/usr/libexec/dsh-session-export.js");
    NSArray<NSString *> *candidates = @[
        bootstrapCopy ?: @"/usr/libexec/dsh-session-export.js",
        @"/var/mobile/Documents/dsh/bin/dsh-session-export.js",
        @"/var/mobile/.dsh/bin/dsh-session-export.js",
    ];
    NSString *script = nil;
    for (NSString *candidate in candidates) {
        if ([manager fileExistsAtPath:candidate]) {
            script = candidate;
            break;
        }
    }
    if (script.length == 0) {
        NSString *bundled = [NSBundle.mainBundle pathForResource:@"dsh-session-export" ofType:@"js"];
        if (bundled.length > 0) {
            script = bundled;
        }
    }
    if (script.length == 0) {
        DSHLog(@"export: script missing, tried %@", candidates);
        if (error) {
            *error = DSHMakeError(ENOENT, @"找不到导出脚本 dsh-session-export.js（重装本包即可修复）");
        }
        return nil;
    }
    DSHLog(@"export: script=%@", script);

    NSString *node = DSHConfigNodePath();
    if (![manager isExecutableFileAtPath:node]) {
        DSHLog(@"export: node missing, configured %@", node);
        if (error) {
            *error = DSHMakeError(ENOENT, @"找不到 node22，请在 dsh-ts/config.json 里写 nodePath");
        }
        return nil;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    char *envp[] = {
        "HOME=/var/mobile",
        "PATH=/var/jb/usr/local/bin:/var/jb/usr/bin:/usr/bin:/bin",
        "TMPDIR=/tmp",
        NULL
    };
    const char *nodePath = node.fileSystemRepresentation;
    const char *scriptPath = script.fileSystemRepresentation;
    char *argv[] = { (char *)nodePath, "--jitless", (char *)scriptPath, NULL };

    pid_t pid = 0;
    int result = posix_spawn(&pid, nodePath, &actions, NULL, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    if (result != 0) {
        DSHLog(@"export: spawn -> %s", strerror(result));
        if (error) {
            *error = DSHMakeError(result, @"无法运行导出脚本");
        }
        return nil;
    }

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        if (error) {
            *error = DSHMakeError(errno, @"导出脚本没有正常结束");
        }
        return nil;
    }
    BOOL ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
    DSHLog(@"export: exit=%d status=%d", ok, status);

    NSString *exportPath = @"/var/mobile/Documents/dsh-backup/exports/latest.md";
    NSDictionary *attributes = [manager attributesOfItemAtPath:exportPath error:NULL];
    if (!attributes || [attributes fileSize] == 0) {
        if (error) {
            *error = DSHMakeError(ok ? ENOENT : EIO,
                                  @"导出没有产出文件，请确认 dsh 会话目录存在");
        }
        return nil;
    }
    return exportPath;
}


+ (void)runCapabilitySelfCheck {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *shell = ApelinBootstrapPath(@"/bin/sh");
    NSString *launcher = DSHPathForFileName(DSHLauncherName);
    DSHLog(@"selfcheck: shell=%@ exists=%d exec=%d",
           shell, [manager fileExistsAtPath:shell], [manager isExecutableFileAtPath:shell]);
    DSHLog(@"selfcheck: launcher exists=%d exec=%d",
           [manager fileExistsAtPath:launcher], [manager isExecutableFileAtPath:launcher]);

    if (shell) {
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/private/var/tmp/dsh-spawn-check.log",
                                         O_WRONLY | O_CREAT | O_TRUNC, 0644);
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/private/var/tmp/dsh-spawn-check.log",
                                         O_WRONLY | O_APPEND, 0644);
        char *argv[] = { (char *)shell.fileSystemRepresentation, "-c", "echo spawn-ok", NULL };
        pid_t childPID = 0;
        int result = posix_spawn(&childPID, shell.fileSystemRepresentation, &actions, NULL, argv, NULL);
        posix_spawn_file_actions_destroy(&actions);
        DSHLog(@"selfcheck: spawn %@ -> %d (%s)", shell, result, result == 0 ? "ok" : strerror(result));
        if (result == 0) {
            int status = 0;
            waitpid(childPID, &status, 0);
        }
    }

    NSInteger dshPID = [self currentPID];
    if (dshPID > 0) {
        int signaled = kill((pid_t)dshPID, 0);
        DSHLog(@"selfcheck: kill(%ld, 0) -> %d (%s)", (long)dshPID, signaled,
               signaled == 0 ? "ok" : strerror(errno));
    }
}

+ (BOOL)controlDaemonInstalled {
    NSString *plist = ApelinBootstrapPath(@"/Library/LaunchDaemons/bc.8848.dshcontrol.control.plist");
    return plist.length > 0 && [NSFileManager.defaultManager fileExistsAtPath:plist];
}

+ (BOOL)requestControlCommand:(NSString *)command {
    NSDictionary *request = @{ @"command": command ?: @"",
                               @"time": @(NSDate.date.timeIntervalSince1970) };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:&error];
    if (!data) {
        DSHLog(@"daemon: encode failed %@", error.localizedDescription);
        return NO;
    }
    BOOL written = [data writeToFile:DSHControlRequestPath atomically:YES];
    DSHLog(@"daemon: request %@ written=%d", command, written);
    return written;
}

+ (NSDictionary *)controlResultNewerThan:(NSTimeInterval)timestamp {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:DSHControlResultPath error:NULL];
    NSDate *modified = attributes[NSFileModificationDate];
    if (!modified || modified.timeIntervalSince1970 < timestamp) {
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:DSHControlResultPath];
    if (data.length == 0) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

+ (void)removeControlRequest {
    [NSFileManager.defaultManager removeItemAtPath:DSHControlRequestPath error:NULL];
}

+ (BOOL)writeHelperResult:(NSDictionary *)result command:(NSString *)command {
    NSMutableDictionary *payload = [result mutableCopy] ?: [NSMutableDictionary dictionary];
    payload[@"command"] = command ?: @"";
    payload[@"date"] = @(NSDate.date.timeIntervalSince1970);
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (!data) {
        DSHLog(@"helper result: encode failed %@", error.localizedDescription);
        return NO;
    }
    BOOL written = [data writeToFile:DSHHelperResultPath atomically:YES];
    DSHLog(@"helper result: written=%d %@", written, payload);
    return written;
}

+ (NSDictionary *)helperResultNewerThan:(NSTimeInterval)timestamp {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:DSHHelperResultPath error:NULL];
    NSDate *modified = attributes[NSFileModificationDate];
    if (!modified || modified.timeIntervalSince1970 < timestamp) {
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:DSHHelperResultPath];
    if (data.length == 0) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

+ (void)removeHelperResult {
    [NSFileManager.defaultManager removeItemAtPath:DSHHelperResultPath error:NULL];
}

@end

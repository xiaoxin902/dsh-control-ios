#import "DSHConfig.h"

NSString *const DSHConfigPath = @"/var/mobile/Documents/dsh-tools/config.json";

static NSString *const DSHDefaultDirectory = @"/var/mobile/Documents/dsh";
static NSString *const DSHDefaultNode = @"/var/jb/usr/local/bin/node22";
static NSString *const DSHDefaultPath =
    @"/var/jb/usr/local/bin:/var/jb/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin";
static NSString *const DSHDefaultTmp = @"/var/mobile/Documents/dsh/tmp";

/// 用户自带的 node 常放在 Documents 下，作为 /var/jb 之外的候选。
static NSString *const DSHFallbackNode = @"/var/mobile/Documents/dsh-tools/bin/node22";

NSDictionary<NSString *, NSString *> *DSHConfigValues(void) {
    NSMutableDictionary<NSString *, NSString *> *values = [@{
        @"dshDir" : DSHDefaultDirectory,
        @"nodePath" : DSHDefaultNode,
        @"path" : DSHDefaultPath,
        @"tmpDir" : DSHDefaultTmp,
    } mutableCopy];

    NSData *data = [NSData dataWithContentsOfFile:DSHConfigPath];
    if (data.length > 0) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([parsed isKindOfClass:NSDictionary.class]) {
            for (NSString *key in values) {
                id value = ((NSDictionary *)parsed)[key];
                if ([value isKindOfClass:NSString.class] && [value length] > 0) {
                    values[key] = value;
                }
            }
        }
    }
    return values;
}

NSString *DSHConfigNodePath(void) {
    NSFileManager *manager = NSFileManager.defaultManager;
    // 包内的 node22 优先于任何配置：它跟着 App 一起来，路径最确定。
    NSString *bundled = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"bin/node22"];
    if ([manager isExecutableFileAtPath:bundled]) {
        return bundled;
    }
    NSString *configured = DSHConfigValues()[@"nodePath"];
    if ([manager isExecutableFileAtPath:configured]) {
        return configured;
    }
    for (NSString *candidate in @[ DSHFallbackNode, @"/usr/local/bin/node22" ]) {
        if ([manager isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }
    return configured;
}

NSString *DSHConfigSearchPath(void) {
    NSString *configured = DSHConfigValues()[@"path"];
    NSString *nodeDirectory = [DSHConfigNodePath() stringByDeletingLastPathComponent];
    if (nodeDirectory.length == 0) {
        return configured;
    }
    // node 所在目录排在最前，用户自己带来的 node 才找得到。
    return [[nodeDirectory stringByAppendingString:@":"] stringByAppendingString:configured];
}

NSString *DSHConfigTmpDirectory(void) {
    return DSHConfigValues()[@"tmpDir"];
}

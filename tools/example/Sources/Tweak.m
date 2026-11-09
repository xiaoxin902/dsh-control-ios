// 最小可用的越狱插件示例：注入 SpringBoard，挂钩一个方法并打日志。
// 用 tools/ios-tweak-build.sh 编译：
//   NAME=ExampleTweak PKG=bc.8848.exampletweak FILTER=com.apple.springboard \
//     SRC=tools/example/Sources ./tools/ios-tweak-build.sh
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <substrate.h>

static os_log_t gLog;
static void (*originalDidFinishLaunching)(id, SEL, id);

static void hookedDidFinishLaunching(id self, SEL _cmd, id application) {
    os_log(gLog, "ExampleTweak: applicationDidFinishLaunching");
    if (originalDidFinishLaunching) {
        originalDidFinishLaunching(self, _cmd, application);
    }
}

__attribute__((constructor)) static void ExampleTweakInit(void) {
    gLog = os_log_create("bc.8848.exampletweak", "load");
    os_log(gLog, "ExampleTweak loaded");
    Class cls = objc_getClass("SpringBoard");
    SEL sel = @selector(applicationDidFinishLaunching:);
    if (cls && class_getInstanceMethod(cls, sel)) {
        MSHookMessageEx(cls, sel, (IMP)hookedDidFinishLaunching,
                        (IMP *)&originalDidFinishLaunching);
    }
}

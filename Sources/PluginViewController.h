// 插件管理：列出 profile 里已装的插件、列出可安装的 .tgz，点一下装。
//
// App 本身在沙箱里看不到 ~/.dsh，所以这里所有读写都交给控制守护进程：
// 写请求文件 → 守护进程跑 dsh-plugin.js → 读回来的结果 JSON。
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PluginViewController : UITableViewController

@end

NS_ASSUME_NONNULL_END

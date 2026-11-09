// 运行环境探测：越狱安装里这些路径是固定的；TrollStore 安装里没有
// /var/jb，用户也不一定把 dsh 放在默认位置，所以允许用一份 JSON 覆盖。
//
// 覆盖文件：/var/mobile/Documents/dsh-ts/config.json
// {
//   "dshDir":   "/var/mobile/Documents/dsh",
//   "nodePath": "/var/mobile/Documents/dsh-ts/bin/node22",
//   "path":     "/var/mobile/Documents/dsh-ts/bin:/var/jb/usr/bin:/usr/bin:/bin",
//   "tmpDir":   "/var/mobile/Documents/dsh/tmp"
// }
// 缺字段就用默认值；解析失败也退回默认值，绝不因为配置写错而不启动。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 覆盖文件路径。文件不存在时所有取值都是默认值。
FOUNDATION_EXPORT NSString *const DSHConfigPath;

/// 整份配置（默认值 + 覆盖文件），永不返回 nil。
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *DSHConfigValues(void);

/// node22 的实际路径：配置里的，或默认候选里第一个存在的。
FOUNDATION_EXPORT NSString *DSHConfigNodePath(void);

/// 启动子进程时用的 PATH。
FOUNDATION_EXPORT NSString *DSHConfigSearchPath(void);

/// 子进程的 TMPDIR（iOS 上 /tmp 可写，dsh 自己的 tmp 目录也行）。
FOUNDATION_EXPORT NSString *DSHConfigTmpDirectory(void);

NS_ASSUME_NONNULL_END

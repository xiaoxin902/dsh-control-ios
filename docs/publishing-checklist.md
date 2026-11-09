# 从私密转公开发布前的检查清单

仓库现在是 **private**。改成 public 之前，这些必须处理——它们已经在 git 历史里了，
所以"删除文件"是不够的，要么重写历史，要么另建一个干净仓库（推荐后者更省事）。

## 必须清掉

- `Attachments/` —— 设备截图，含状态栏、时间、电量等个人痕迹
- `dsh-memory/AGENTS.md` —— 你个人写给 dsh 的指令与偏好
- `dsh-docs/` —— 个人整理的文档副本
- 任何 `*.bak-*` 备份文件
- `/tmp` 路径与设备上真实的会话 id、包名里的个人线索（`tools/` 里的示例可以留）

## 检查

```sh
git log --all --stat | grep -iE 'Attachments|dsh-memory|dsh-docs|\.bak-'
```

## 如果要保留历史

```sh
# 在新目录里重建，只带需要的文件
git clone --no-hardlinks . ../dsh-control-public
cd ../dsh-control-public
git filter-repo --invert-paths --path Attachments --path dsh-memory --path dsh-docs  # 需安装 git-filter-repo
```

## 发布前也确认

- `LICENSE` 里的年份与署名
- `README.md` 里"巨魔版未验证"这段仍然属实
- `apelin-project.json` 里的包标识 `bc.8848.dshcontrol` 是你要长期用的
- 仓库里不含任何 token、密钥、设备 UDID

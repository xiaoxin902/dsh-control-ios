# 从私密转公开发布前的检查清单

仓库 **xiaoxin902/dsh-control-ios** 已经是干净的：历史两个提交里都没有个人文件
（`Attachments/`、`dsh-memory/`、`dsh-docs/` 从未出现在这个仓库的历史中，
它们仍留在本地项目的 `.private-archive/`，被 `.gitignore` 忽略）。

所以转公开只需要做最后几步，不必再重写历史。

## 转公开前确认

1. `README.md` 描述与当前版本一致（1.3.2）
2. `LICENSE` 的年份与署名（8848, 2026）
3. `apelin-project.json` 里的包标识 `bc.8848.dshcontrol` 是你要长期用的
4. 仓库里不含 token、密钥、设备 UDID、真实的会话 id

## 转公开

GitHub → 仓库 → Settings → 最下面 **Danger Zone** → Change repository visibility → Public。

## 旧的 `dsh-control` 仓库

它是早期历史（含截图等个人文件），确认新仓库内容无误后删除：
Settings → Danger Zone → Delete this repository。
这个操作只能由账号所有者在网页上完成。

# 发布前检查清单

你给出 GitHub 用户名和仓库名后，发布前只需要重点确认下面这些点。

## 1. 替换脚本自更新地址

编辑 `gost.sh` 顶部变量：

- `repo_slug_default`
- `repo_branch_default`
- `self_update_url`

## 2. 替换 README 下载命令

当前 README 的下载命令指向现仓库，需要改成你自己的：

```bash
curl -fsSL -o gost.sh https://raw.githubusercontent.com/<owner>/<repo>/<branch>/gost.sh && chmod +x gost.sh && ./gost.sh
```

## 3. 选择默认分支

脚本目前按 `v2` 分支组织。如果你准备改成：

- `main`
- `master`
- 其他发布分支

需要同步更新：

- README 下载命令
- `gost.sh` 顶部自更新地址

## 4. 上传前建议确认

- `bash -n gost.sh`
- `gost.service` 指向 `/etc/gost/config.yaml`
- `config.yaml` 为占位模板
- `README.md`、`CHANGELOG.md`、`docs/` 已随仓库上传

## 5. 推荐的首个发布内容

- `gost.sh`
- `gost.service`
- `config.yaml`
- `README.md`
- `CHANGELOG.md`
- `docs/`
- `LICENSE`

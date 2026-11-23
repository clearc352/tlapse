# 推送到 GitHub

本仓库根目录应是 `tlapse/`，不是它外层的 `iphone6/`。
外层 AI 工作记录、设备验收材料和旧方案不属于公开仓库。

## 1. 创建空仓库

登录 GitHub，新建仓库，名称可用 `tlapse`，选择 Public。
不要勾选自动添加 README、`.gitignore` 或许可证，本地已经提供这些文件。
创建后记下 HTTPS 仓库地址，例如 `https://github.com/YOUR_USERNAME/tlapse.git`。

## 2. 本地初始化与检查

在本机进入 `tlapse/` 后执行：

```sh
git init -b main
git status --short --untracked-files=all
git add .
git diff --cached --stat
git diff --cached --check
git diff --cached
```

提交前逐项检查：

- 只有源码、测试、文档、锁文件、示例配置和必要安装配置。
- 没有 `.trellis/`、`node_modules/`、`.theos/`、deb、压缩备份或生成网页。
- 没有正式 `config.json`、SSH 密钥、Telegram token、WebDAV 密码、私人照片或设备日志。
- 历史规格、阶段记录和压缩备份不属于公开内容；不使用 `git add -f` 强行加入。

如果误暂存文件，在首次提交前可用 `git rm --cached -- "文件路径"` 仅移出暂存区、保留本地文件，
再完善 `.gitignore`。对于目录需加 `-r`，执行前仔细核对路径。
已提交过的文件不受新增 `.gitignore` 保护；若提交过真实凭据，先轮换凭据，再处理历史，不能只删除最新文件。

## 3. 提交与推送

确认 Git 作者信息使用你愿意公开的名字和邮箱，可使用 GitHub 提供的 noreply 邮箱。
如果尚未配置，设置本仓库信息：

```sh
git config user.name "YOUR_NAME"
git config user.email "YOUR_GITHUB_NOREPLY_EMAIL"
```

将示例替换成自己的真实设置后再执行。然后提交、连接远端：

```sh
git commit -m "Initial open-source release"
git remote add origin https://github.com/YOUR_USERNAME/tlapse.git
git push -u origin main
```

远端地址中的 `YOUR_USERNAME` 必须替换。HTTPS 使用浏览器/凭据管理器或最小权限访问令牌认证，
不能使用 GitHub 账户密码；不要把访问令牌写进远端 URL、脚本或仓库。
若已配置 GitHub SSH，也可将远端改用 `git@github.com:YOUR_USERNAME/tlapse.git`。

推送后在 GitHub 检查 README、文件列表和许可证识别结果。
如果提示远端已有提交，先检查是否误勾选了初始化文件，不要直接强制推送覆盖。

## 4. 后续开发

每次开始前确保工作区干净，或先提交/妥善保存本地修改：

```sh
git switch main
git pull --ff-only
git switch -c feat/short-description
```

完成修改并运行[相关测试](development.md)后：

```sh
git add "具体修改的文件"
git diff --cached
git commit -m "Describe the change"
git push -u origin feat/short-description
```

在 GitHub 发起 Pull Request，合并后再同步本地主分支。
源码进 Git；需要发布安装包时，把选定且验证过的 deb 放到 GitHub Releases，
附 SHA-256、适用环境和验证范围，不把整个 `packages/` 目录提交进仓库。

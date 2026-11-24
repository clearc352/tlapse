# 安装与使用

## 环境与安装

面向已越狱的 iPhone 6、iOS 12.5.7、rootful 环境，设备需安装 OpenSSH。
其他机型、系统和 rootless 环境未验证。越狱方法不在本文范围内。

先按[开发说明](development.md)从源码生成两个 deb：

- `packages/` 中的 `com.ddxyl.tlapse`：守护进程、网页和主屏幕 App「帧轨」。
- `camfix/packages/` 中的 `com.ddxyl.tlapse-camera`：后台摄像头支持，包含动态库和注入器。

备份手机已有的 `/var/mobile/Timelapse/`，将选定的两个 deb 拷到手机，在手机 root shell 中依次安装：

```sh
dpkg -i /tmp/tlapse.deb
dpkg -i /tmp/tlapse-camera.deb
```

这里的文件名是示例，需换成拷贝后的实际名称。不要用通配符安装整个历史包目录。
安装会启动服务；首次安装的示例项目全部暂停，上传关闭，弱示例口令不会开放网页端口。
升级不覆盖已有 `config.json`，也不重置项目状态；已有启用项目可能在服务重启后继续工作，升级前先暂停。
摄像头包的升级或卸载可能重启 `mediaserverd`，短暂影响系统媒体服务，应单独安排。

## 首次配置

正式配置：`/var/mobile/Timelapse/config.json`。完整字段见
[config.example.json](../layout/var/mobile/Timelapse/config.example.json)。

1. 在电脑本地生成随机口令：`python3 -c 'import secrets; print(secrets.token_urlsafe(24))'`。
2. 将结果填入手机配置的 `server.token`，不要提交或公开该值。
3. 保持项目 `enabled: false`，先检查存储空间、拍摄方向和声音设置。
4. 保存后自动重载。用其他设备的现代浏览器访问 `http://手机局域网IP:8080` 或 `http://iphone.local:8080`。

`server.token` 至少 16 字符，不能使用 `change-me`。设备不需要 Node.js。
项目目录和照片不会出现在系统「照片」中。

在 iPhone 上打开主屏幕的「帧轨」，用 `127.0.0.1:8080`（或实际配置的端口）和同一个口令登录。
如果 App 图标没有出现，在手机的 root shell 执行 `uicache -p /Applications/Tlapse.app`（旧版 `uicache` 不支持 `-p` 时，直接执行 `uicache`）。
App 可新建项目、暂停或继续拍摄、手动拍照，调整名称、间隔、分辨率和快门声，
也可查看最新照片、按日浏览照片、左滑删除单张照片，以及合成和播放视频。
其他高级配置仍可在网页上编辑。

## 拍摄与配置

网页支持创建/编辑/暂停项目、手动拍照、按日浏览照片、下载和删除照片、合成及上传视频、查看日志。
删除项目只移除配置，不删除已有媒体；删除照片同时删除其缩略图，不修改已经合成的视频。

| 配置 | 说明 |
|---|---|
| `capture.interval` | 拍摄间隔秒数，最小 5 |
| `capture.resolution` | `1920x1440` 或 `full`，按方向等比缩小 |
| `capture.orientation` | `auto`、`raw`、`portrait`、`portraitUpsideDown`、`landscapeHomeRight`、`landscapeHomeLeft` |
| `capture.lockFocus` / `lockExposure` / `lockWhiteBalance` | 稳定后锁定相机参数 |
| `capture.jpegQuality` | 0.1 到 1，默认 0.85 |
| `capture.settleSeconds` | 对焦等待时间，0.3 到 5 秒 |
| `capture.shutterSound` | 默认 true；false 时严格请求静音，不支持或授权不足则失败，不回退有声 |
| `capture.nightSkip` | false、true，或带 `from`、`to`、`brightness` 的对象 |
| `encode.mode` | `daily` 使用单日照片，`cumulative` 使用全部照片 |
| `encode.at` / `fps` / `targetDuration` | 自动合成时间、帧率、可选目标时长；超长时抽帧 |
| `cleanup.keepFramesDays` | 合成成功后保留原图的天数 |
| `storage.minFreeGB` | 最小可用空间，示例为 5GB |

`nightSkip: true` 默认跳过 22:00 到 06:00；亮度阈值大于 0 时，过暗照片拍完后丢弃。
手动拍照忽略夜间时间窗口，但仍可能因亮度或存储限制跳过。
手机平放时 `auto` 方向可能不可靠，建议显式指定方向。

静音使用私有 API 和程序专用签名授权，不修改系统音量或音效。
单台 iPhone 6 / iOS 12.5.7 已有单张实际无声确认，不保证所有设备、地区或系统都无声。
外层失败重试最多可能产生两次曝光；开始长时间拍摄前，应在合适环境中少量实拍确认。

## 命令行

以下命令在手机上执行。手动拍摄、合成和上传即使项目暂停也能执行；它们会产生实际操作。

```sh
/usr/local/bin/tlapsed status
/usr/local/bin/tlapsed snap --project mungbean
/usr/local/bin/tlapsed encode --project mungbean --date 20261120
/usr/local/bin/tlapsed upload --project mungbean
```

程序支持 `--config PATH`。照片保存在
`/var/mobile/Timelapse/projects/<id>/frames/<YYYYMMDD>/<HHMMSS>.jpg`，
缩略图位于相同项目的 `thumbs/` 中。

确认单张拍摄正常后，再手动启用项目的 `enabled`，定时任务才开始运行。
项目共用串行相机队列；重启后不会集中补拍错过的帧。

## 上传与清理

Telegram / WebDAV 需同时在全局 `uploads` 中启用，并在项目 `upload` 数组列出目标。
账号与密钥仅在手机配置中填写，网页不展示这些值；`ENV:` 不会被展开为环境变量。
WebDAV 要求 HTTPS。上传失败可能重试，不能把网络中断当成操作未发生。

启用自动合成和清理前先备份媒体。合成成功会清理超过保留期的原图及缩略图；
磁盘不足时，还可能先清理已有成功上传记录的项目中今天以前的原图，再决定暂停拍照。

## 安全边界

- 仅在可信局域网或受控 VPN 内使用；没有 HTTPS，不做公网端口转发。
- 服务不绑定蜂窝网，限制接口和地址范围，并校验 Host；这些限制不是互联网暴露的安全保证。
- 登录使用 12 小时 HttpOnly 会话 Cookie；连续 8 次口令错误会锁定来源地址 5 分钟。
- 拍摄对象应知情同意，并遵守当地有关隐私、录制与快门声音的规定。
- 报告问题前脱敏配置、日志和截图，绝不附带真实口令、SSH 密钥、上传凭据或私人照片。

## 排错与停机

日志目录：`/var/mobile/Timelapse/logs/`，重点检查 `tlapsed.log`、
`launchd.out.log`、`launchd.err.log` 和 `uploads.log`。
状态保存在 `state.json`，上传队列在日志目录的 `upload-queue.json`。

```sh
tail -f /var/mobile/Timelapse/logs/tlapsed.log
launchctl unload /Library/LaunchDaemons/com.ddxyl.tlapsed.plist
```

日志出现“方向 … 尺寸=…”才表示照片已写入；仅“已关闭摄像头”不代表保存成功。
网络中断时不要马上重复拍摄、删除或上传，先核对状态。
不要给主服务 launchd plist 添加 `UserName`：进程需要先以 root 调整自身 96MB 内存上限，再切换到 mobile。
卸载软件包不会删除已有照片，删除媒体需另行备份并确认。

# 开发与构建

所有命令默认从本仓库根目录执行。主机测试和打包以 macOS 为基准。

## 依赖

- macOS Command Line Tools / Xcode，提供 `clang`、`make` 和 `xcrun`。
- [Theos](https://theos.dev/docs/installation) 与可用的 iPhoneOS SDK，自行安装到工具链中。
- 支持 `-Cadhoc` 的 `ldid` 和 Theos 所需的 deb 打包工具。注入器使用 `ldid -S -Cadhoc`，不用 `codesign -s -` 替代。
- Node.js 24 LTS 与 npm，用于前端及浏览器测试；手机不需要 Node.js。

目标为 `arm64`、iOS 12.0+、rootful。不要设置 `THEOS_PACKAGE_SCHEME=rootless`。
实际兼容性以 iPhone 6 / iOS 12.5.7 的验证为限，不因编译目标而承诺其他环境。

## 前端

```sh
npm --prefix web ci
npm --prefix web run dev:mock
```

Mock 登录口令为 `demo`，仅用于假数据预览，不访问手机，也不进入生产包。

连接已配置好的手机进行开发：

```sh
cd web
PHONE=http://iphone.local:8080 npm run dev
```

也可将 `PHONE` 换成手机局域网地址。未指定时只代理到 `127.0.0.1:8080`，不会自动访问旧设备。
开发服务器绑定所有网卡，仅应在可信网络启动。连接手机后的拍摄、删除、上传是真实操作，不是 Mock。
网页使用现代浏览器、hash 路由和本地字体，不为设备自身的 iOS 12 Safari 做兼容降级。

## 打包

```sh
export THEOS="$HOME/theos"
npm --prefix web ci
npm --prefix web run build
make package FINALPACKAGE=1
make -C camfix package FINALPACKAGE=1
```

顺序不能省略：网页产物不提交 Git，必须先构建，再打包主程序。
产物分别在 `packages/` 和 `camfix/packages/`，仅本地生成，不自动安装到手机。
若源码来自 ZIP，打包器仍可能需要本机 Git 工具，但不需要已有 GitHub 远端。
仅安装 Command Line Tools 时，可以将 `iPhoneOS12.4.sdk` 放在 `$THEOS/sdks/`，
执行 `make package TARGET=iphone:clang:12.4:12.0 MODULESFLAGS=-fno-modules FINALPACKAGE=1`。
禁用 Clang 模块可避免较新编译器拒绝 SDK 中旧格式的 module map。

`camfix/` 的一个 deb 同时包含从源码构建的 `TlapseCameraFix.dylib` 和 `tlapse-camera-inject`。
动态库安装到 `/usr/lib/`，注入器安装到 `/usr/local/bin/`，只为 `tlapsed` 的后台摄像头使用提供例外。
修改摄像头组件或签名后必须单独做真机回归；能打包不表示可安全替换设备上的现有注入器。

## 测试

在 macOS 运行现有逻辑测试，不访问手机：

```sh
make test HOST_TEST_CFLAGS=-O2
node --test web/tests/*.test.js
```

真实 TLWeb 浏览器回归使用本机生成的 JPEG 和 H.264 视频，需要 Node.js 24 和安装在默认位置的 Google Chrome。
先构建网页，再在终端 A 运行：

```sh
make test-web-fixture
FIXTURE_ROOT="$(mktemp -d /tmp/tlapse-fixture.XXXXXX)"
printf '夹具目录：%s\n' "$FIXTURE_ROOT"
/tmp/tlapse-web-fixture "$FIXTURE_ROOT" "$PWD/layout/var/mobile/Timelapse/web/index.html"
```

服务就绪后保持终端 A 运行。在终端 B 中，将路径替换为刚打印的实际目录：

```sh
EVIDENCE_ROOT="$(mktemp -d /tmp/tlapse-browser.XXXXXX)"
node web/tests/browser-regression.mjs /tmp/tlapse-fixture.XXXXXX/fixture.json "$EVIDENCE_ROOT"
```

完成后在终端 A 按 Ctrl-C 停止夹具。测试数据和证据放在系统临时目录，不提交到仓库。
这些检查不证明真实摄像头、熄屏调度、千帧编码内存、上传送达或长期稳定性通过。
目前没有独立 lint / typecheck 脚本，不把构建通过描述为这两项检查通过。

## 目录与贡献

| 路径 | 内容 |
|---|---|
| `src/` | Objective-C 守护进程、自建 HTTP 服务、拍摄/调度/合成/上传 |
| `camfix/` | 后台摄像头动态库、注入器及安装配置 |
| `web/` | Vue 3 网页、开发 Mock 和前端测试 |
| `tests/` | macOS 主机测试及真实 TLWeb 夹具 |
| `layout/` | launchd、安装脚本、示例配置；网页目录为生成物 |

接口实现见 [TLWeb.m](../src/TLWeb.m)，前端请求封装见 [api.js](../web/src/lib/api.js)。
提交改动时说明行为变化和验证范围，
保持示例项目暂停、上传关闭；不要附带设备配置、密钥、私人媒体、SDK 或构建产物。
更新前端运行时或字体依赖时，同步核对[第三方许可](../THIRD_PARTY_NOTICES.md)。
涉及设备实操的验证应明确取得设备所有者授权，与本地测试分开记录。

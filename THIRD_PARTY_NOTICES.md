# 第三方许可

本项目自身代码使用 [MIT](LICENSE)。第三方依赖保留各自的版权与许可，不因本项目采用 MIT 而改变。

| 组件 | 许可 | 用途 |
|---|---|---|
| Vue 3 及 `@vue/*` 运行时 | MIT | 网页界面 |
| vue-router | MIT | 网页路由 |
| Inter / `@fontsource/inter` | OFL-1.1 | 本地字体 |
| Instrument Serif / `@fontsource/instrument-serif` | OFL-1.1 | 本地字体 |

随网页分发的完整版权与许可位于 [THIRD-PARTY-LICENSES.txt](web/public/THIRD-PARTY-LICENSES.txt)；
Vite 会将其原样复制到安装包的 `/var/mobile/Timelapse/web/`。
更新上述依赖时应同步核对该文件。

构建工具及其他间接依赖的确切版本和许可见 `web/package-lock.json` 及对应 npm 包的许可文件。
Theos、Apple SDK 和越狱工具不是本仓库的一部分，需自行获取并遵守各自条款；不要把 SDK 或工具链提交到仓库。

# tlapse 网页控制台

Vue 3 + vue-router（hash 路由）+ Vite，使用 Motion for Vue 做页面过渡、卡片布局和拖动预览；新增的媒体组件使用 TypeScript。网页运行在其他设备的现代浏览器中，媒体存储在 iPhone 上。

在本目录执行：

```sh
npm ci
npm run dev:mock                           # 假数据预览，口令 demo
PHONE=http://iphone.local:8080 npm run dev  # 代理到已授权的真实手机
node --test tests/*.test.js
npm run typecheck
npm run build
```

未指定 `PHONE` 时仅代理到 `127.0.0.1:8080`。真实设备代理中的拍摄、删除和上传会直接操作手机。
构建产物写入 `../layout/var/mobile/Timelapse/web/`，不提交 Git；手机不需要 Node.js。
本地字体和第三方许可随产物一起分发，不依赖 CDN。Mock 不进入生产包。

接口实现见 [TLWeb.m](../src/TLWeb.m)，请求与错误处理见 [api.js](src/lib/api.js)；
完整构建和真实 TLWeb 浏览器验证步骤见[开发说明](../docs/development.md)。
Mock 只用于预览，不替代 HTTP 集成或真机测试。

## v5 界面与媒体预览

- 使用「帧轨」标志、MiSans 字体和暖白 / 墨黑 / 浅绿配色；桌面图标侧栏在手机上变为底部导航。
- 项目卡片的拖动条在首次操作时才读取最近一天的照片列表；详情页提供时间轴、横向拖动和最多 9 张抽样缩略图。预览不会预取整天原图，打开大图时才读取对应原图。
- 时间轴支持方向键、Home / End。网格、多选、Shift 连选、跨日期下载 / 删除快照和大图操作保留。
- 视频加载失败或 20 秒内未得到可用媒体状态会显示重试；重试只重新读取视频，不会重放合成或上传。
- 动画遵循系统减少动态效果的偏好。Mock 视频故意返回 404，可用于验证错误状态。

MiSans 字形与名称保持原样，仅转换为 WOFF2 容器；4 个完整字重共约 16.8 MB，
使用 font-display: swap，不访问第三方 CDN。字体许可不属于项目 MIT 许可，
见随构建分发的 [MiSans 字体知识产权许可协议](public/MiSans-License.pdf)。

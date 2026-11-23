# tlapse 网页控制台

Vue 3 + vue-router（hash 路由）+ Vite。网页运行在其他设备的现代浏览器中，媒体存储在 iPhone 上。

在本目录执行：

```sh
npm ci
npm run dev:mock                           # 假数据预览，口令 demo
PHONE=http://iphone.local:8080 npm run dev  # 代理到已授权的真实手机
node --test tests/*.test.js
npm run build
```

未指定 `PHONE` 时仅代理到 `127.0.0.1:8080`。真实设备代理中的拍摄、删除和上传会直接操作手机。
构建产物写入 `../layout/var/mobile/Timelapse/web/`，不提交 Git；手机不需要 Node.js。
本地字体和第三方许可随产物一起分发，不依赖 CDN。Mock 不进入生产包。

接口实现见 [TLWeb.m](../src/TLWeb.m)，请求与错误处理见 [api.js](src/lib/api.js)；
完整构建和真实 TLWeb 浏览器验证步骤见[开发说明](../docs/development.md)。
Mock 只用于预览，不替代 HTTP 集成或真机测试。

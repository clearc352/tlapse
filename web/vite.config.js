import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { fileURLToPath } from 'node:url'
import { mockApi } from './mock/mock-api.js'

// 开发时把 /api 代理到手机：PHONE=http://iphone.local:8080 npm run dev
// 没有手机时用假数据预览：npm run dev:mock
const PHONE = process.env.PHONE || 'http://127.0.0.1:8080'

export default defineConfig(({ mode }) => ({
  base: './',
  plugins: [vue(), mode === 'mock' ? mockApi() : null].filter(Boolean),
  build: {
    outDir: fileURLToPath(new URL('../layout/var/mobile/Timelapse/web', import.meta.url)),
    emptyOutDir: true,
    assetsDir: 'assets',
    // 生产 CSP 的 img-src/font-src 不允许 data:，小文件也不要内联
    assetsInlineLimit: 0,
    target: 'es2020',
    cssCodeSplit: false,
    modulePreload: { polyfill: false },
    reportCompressedSize: false,
  },
  server: {
    host: true,
    proxy: mode === 'mock' ? undefined : {
      '/api': { target: PHONE, changeOrigin: true },
    },
  },
}))

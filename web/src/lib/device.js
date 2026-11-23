import { reactive } from 'vue'
import { api } from './api.js'

// 共享的设备状态（/api/status），总览页和顶栏共用，避免重复请求手机
export const device = reactive({ data: null, loading: false, error: null, at: 0 })

let inflight = null
export function refreshDevice(force = false) {
  if (inflight) return inflight
  if (!force && device.data && Date.now() - device.at < 8000) return Promise.resolve(device.data)
  device.loading = true
  inflight = api.status()
    .then((d) => { device.data = d; device.error = null; device.at = Date.now(); return d })
    .catch((e) => { device.error = e; throw e })
    .finally(() => { device.loading = false; inflight = null })
  return inflight
}

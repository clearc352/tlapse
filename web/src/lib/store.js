import { reactive } from 'vue'

// 连接状态：网络失败时显示横幅，但不退出登录
export const conn = reactive({ online: true, lastFailAt: 0 })

// 轻提示
export const toasts = reactive({ list: [] })
let seq = 0
export function toast(message, tone = 'info', ms = 4200) {
  const id = ++seq
  toasts.list.push({ id, message, tone })
  if (ms) setTimeout(() => dismissToast(id), ms)
  return id
}
export function dismissToast(id) {
  const i = toasts.list.findIndex((t) => t.id === id)
  if (i >= 0) toasts.list.splice(i, 1)
}
export function toastError(e) {
  const msg = (e && e.message) || '出错了'
  if (e && (e.kind === 'network' || e.kind === 'timeout')) return toast(msg + '。页面保持不变，网络恢复后再试。', 'warn', 6000)
  if (e && e.kind === 'auth') return null
  return toast(msg, 'danger', 6000)
}

// 确认对话框：await confirmDialog({...}) → true / false
export const dialog = reactive({ open: false, title: '', body: '', confirmText: '确认', tone: 'default', resolve: null })
export function confirmDialog({ title, body = '', confirmText = '确认', tone = 'default' }) {
  return new Promise((resolve) => {
    Object.assign(dialog, { open: true, title, body, confirmText, tone, resolve })
  })
}
export function closeDialog(result) {
  const r = dialog.resolve
  dialog.open = false
  dialog.resolve = null
  if (r) r(result)
}

// 登录态只是一个前端提示，真正以 401 为准
export const session = reactive({ loggedIn: null })

const WEEK = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']

export function parseYmd(ymd) {
  if (!/^\d{8}$/.test(ymd || '')) return null
  return new Date(+ymd.slice(0, 4), +ymd.slice(4, 6) - 1, +ymd.slice(6, 8))
}

export function dateLabel(ymd) {
  const d = parseYmd(ymd)
  if (!d) return ymd
  const today = new Date(); today.setHours(0, 0, 0, 0)
  const diff = Math.round((today - d) / 86400000)
  const md = `${d.getMonth() + 1}月${d.getDate()}日`
  if (diff === 0) return `今天 · ${md}`
  if (diff === 1) return `昨天 · ${md}`
  return `${md} · ${WEEK[d.getDay()]}`
}

export function dateLong(ymd) {
  const d = parseYmd(ymd)
  if (!d) return ymd
  return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日 ${WEEK[d.getDay()]}`
}

export function bytes(n) {
  if (!n && n !== 0) return '—'
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`
  if (n < 1024 ** 3) return `${(n / 1024 / 1024).toFixed(1)} MB`
  return `${(n / 1024 ** 3).toFixed(2)} GB`
}

export function duration(sec) {
  if (sec == null || isNaN(sec)) return '—'
  sec = Math.max(0, Math.floor(sec))
  const d = Math.floor(sec / 86400)
  const h = Math.floor((sec % 86400) / 3600)
  const m = Math.floor((sec % 3600) / 60)
  if (d) return `${d} 天 ${h} 小时`
  if (h) return `${h} 小时 ${m} 分`
  if (m) return `${m} 分钟`
  return `${sec} 秒`
}

export function interval(sec) {
  if (sec == null) return '—'
  if (sec < 60) return `每 ${sec} 秒`
  if (sec % 3600 === 0) return `每 ${sec / 3600} 小时`
  if (sec % 60 === 0) return `每 ${sec / 60} 分钟`
  return `每 ${Math.floor(sec / 60)} 分 ${sec % 60} 秒`
}

export function videoSeconds(frames, fps) {
  if (!frames || !fps) return 0
  return frames / fps
}

export function num(n) {
  if (n == null) return '—'
  return Number(n).toLocaleString('zh-CN')
}

export function encodeEvery(every) {
  if (every === 'daily' || every == null) return '每天'
  if (every === 'weekly') return '每周'
  return `每 ${every} 天`
}

// 从视频文件名里猜出日期，例如 mungbean_20261112_cumulative.mp4
export function videoMeta(name) {
  const m = /_(\d{8})(?:_([a-z]+))?/i.exec(name || '')
  return {
    date: m ? m[1] : null,
    mode: m && m[2] === 'cumulative' ? '累计' : m && m[2] === 'daily' ? '当天' : null,
  }
}

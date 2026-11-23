// 表单 <-> 接口字段的转换。字段名必须和服务端 TLConfig / TLWeb 一致，未知字段会 400。

export const ORIENTATIONS = [
  { v: 'auto', t: '自动', d: '相机没写方向时用重力判断' },
  { v: 'raw', t: '相机原始', d: '只用相机自己写的方向' },
  { v: 'portrait', t: '竖屏', d: 'Home 键在下' },
  { v: 'portraitUpsideDown', t: '竖屏倒置', d: 'Home 键在上' },
  { v: 'landscapeHomeRight', t: '横屏', d: 'Home 键在右' },
  { v: 'landscapeHomeLeft', t: '横屏', d: 'Home 键在左' },
]

export function emptyForm() {
  return fromProject({ capture: {}, encode: {}, cleanup: {}, upload: [] })
}

export function fromProject(p) {
  const c = p.capture || {}
  const e = p.encode || {}
  const n = c.nightSkip
  let nightMode = 'off', nightFrom = '22:00', nightTo = '06:00', nightBrightness = ''
  if (n === true) nightMode = 'default'
  else if (n && typeof n === 'object' && n.enabled !== false) {
    nightMode = 'custom'
    nightFrom = n.from || '22:00'; nightTo = n.to || '06:00'
    nightBrightness = n.brightness != null ? String(n.brightness) : ''
  }
  let everyMode = 'daily', everyDays = 2
  if (e.every === 'weekly') everyMode = 'weekly'
  else if (typeof e.every === 'number') { everyMode = 'days'; everyDays = e.every }
  const res = c.resolution || '1920x1440'
  return {
    id: p.id || '',
    name: p.name || '',
    enabled: !!p.enabled,
    interval: c.interval ?? 300,
    resolution: res,
    orientation: c.orientation || 'auto',
    settleSeconds: c.settleSeconds ?? 1.5,
    jpegQuality: c.jpegQuality ?? 0.85,
    shutterSound: c.shutterSound !== false,
    lockFocus: c.lockFocus !== false,
    lockExposure: c.lockExposure !== false,
    lockWhiteBalance: c.lockWhiteBalance !== false,
    nightMode, nightFrom, nightTo, nightBrightness,
    everyMode, everyDays,
    at: e.at || '23:30',
    mode: e.mode || 'daily',
    fps: e.fps || 30,
    targetDuration: e.targetDuration != null ? String(e.targetDuration) : '',
    keepFramesDays: p.cleanup?.keepFramesDays ?? 14,
    upload: Array.isArray(p.upload) ? [...p.upload] : [],
  }
}

export function toBody(f, { includeId = false } = {}) {
  let nightSkip = false
  if (f.nightMode === 'default') nightSkip = true
  else if (f.nightMode === 'custom') {
    nightSkip = { enabled: true, from: f.nightFrom, to: f.nightTo }
    if (String(f.nightBrightness).trim() !== '') nightSkip.brightness = Number(f.nightBrightness)
  }
  const every = f.everyMode === 'weekly' ? 'weekly' : f.everyMode === 'days' ? Number(f.everyDays) : 'daily'
  const td = String(f.targetDuration).trim()
  const body = {
    name: f.name.trim(),
    enabled: !!f.enabled,
    capture: {
      interval: Number(f.interval),
      resolution: f.resolution.trim(),
      orientation: f.orientation,
      settleSeconds: Number(f.settleSeconds),
      jpegQuality: Number(f.jpegQuality),
      shutterSound: !!f.shutterSound,
      lockFocus: !!f.lockFocus,
      lockExposure: !!f.lockExposure,
      lockWhiteBalance: !!f.lockWhiteBalance,
      nightSkip,
    },
    encode: {
      every,
      at: f.at.trim(),
      mode: f.mode,
      fps: Number(f.fps),
      targetDuration: td === '' ? null : Number(td),
    },
    cleanup: { keepFramesDays: Number(f.keepFramesDays) },
    upload: [...f.upload],
  }
  if (includeId) body.id = f.id.trim()
  return body
}

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

/** 编辑时只发改动过的字段（局部更新），服务器保留其余字段 */
export function diffBody(orig, next) {
  const out = {}
  for (const k of Object.keys(next)) {
    const a = orig[k], b = next[k]
    if (b && typeof b === 'object' && !Array.isArray(b) && a && typeof a === 'object' && !Array.isArray(a)) {
      const sub = {}
      for (const kk of Object.keys(b)) if (!same(a[kk], b[kk])) sub[kk] = b[kk]
      if (Object.keys(sub).length) out[k] = sub
    } else if (!same(a, b)) out[k] = b
  }
  return out
}

const HHMM = /^([01]?\d|2[0-3]):[0-5]\d$/
const HHMM2 = /^([01]\d|2[0-3]):[0-5]\d$/

export function validate(f, isNew) {
  const e = {}
  const num = (v) => (String(v).trim() === '' ? NaN : Number(v))
  if (isNew) {
    if (!f.id) e.id = '请填写 id'
    else if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(f.id)) e.id = '以字母或数字开头，只能用字母、数字、下划线、减号，最长 64 个字符'
  }
  const n = f.name.trim()
  if (n.length < 1 || n.length > 80) e.name = '名称 1 到 80 个字符'
  const iv = num(f.interval)
  if (!Number.isInteger(iv) || iv < 5 || iv > 86400) e.interval = '5 到 86400 秒的整数'
  if (!(f.resolution.trim() === 'full' || /^\d{2,5}x\d{2,5}$/.test(f.resolution.trim()))) e.resolution = '填 full，或「宽x高」，例如 1920x1440'
  const st = num(f.settleSeconds)
  if (!(st >= 0.3 && st <= 5)) e.settleSeconds = '0.3 到 5 秒'
  const q = num(f.jpegQuality)
  if (!(q >= 0.1 && q <= 1)) e.jpegQuality = '0.1 到 1'
  if (f.nightMode === 'custom') {
    if (!HHMM2.test(f.nightFrom) || !HHMM2.test(f.nightTo)) e.night = '开始和结束都要填，格式 HH:MM'
    const b = String(f.nightBrightness).trim()
    if (b !== '' && !(Number(b) >= 0 && Number(b) <= 1)) e.nightBrightness = '0 到 1 之间，留空表示不按亮度丢弃'
  }
  if (f.everyMode === 'days') {
    const d = num(f.everyDays)
    if (!Number.isInteger(d) || d < 1 || d > 366) e.every = '1 到 366 天'
  }
  if (!HHMM.test(f.at.trim())) e.at = '格式 HH:MM，例如 23:30 或 0:10'
  const td = String(f.targetDuration).trim()
  if (td !== '' && !(Number(td) > 0 && Number(td) <= 600)) e.targetDuration = '大于 0、不超过 600 秒；留空表示不抽帧'
  const k = num(f.keepFramesDays)
  if (!Number.isInteger(k) || k < 0 || k > 3650) e.keepFramesDays = '0 到 3650 的整数'
  return e
}

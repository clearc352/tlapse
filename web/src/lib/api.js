// 与守护进程 tlapsed 通讯：
// - Cookie 会话，credentials: same-origin
// - 非 GET/HEAD 加 X-Tlapse-Request: 1
// - 只有 401 才回登录；网络失败留在当前页
import { conn } from './store.js'

export class ApiError extends Error {
  constructor(kind, message, { status = 0, data = null } = {}) {
    super(message)
    this.kind = kind // auth | forbidden | rate | network | timeout | http
    this.status = status
    this.data = data
  }
}

let onUnauthorized = () => {}
export function setUnauthorizedHandler(fn) { onUnauthorized = fn }

export async function request(method, path, body, opts = {}) {
  const { timeout = 20000, allow = [], silentAuth = false } = opts
  const headers = {}
  if (method !== 'GET' && method !== 'HEAD') headers['X-Tlapse-Request'] = '1'
  if (body !== undefined) headers['Content-Type'] = 'application/json'

  const ctrl = new AbortController()
  const timer = timeout ? setTimeout(() => ctrl.abort(), timeout) : null
  let res, text
  try {
    res = await fetch(path, {
      method,
      headers,
      credentials: 'same-origin',
      body: body !== undefined ? JSON.stringify(body) : undefined,
      signal: ctrl.signal,
      cache: 'no-store',
    })
    text = await res.text()
  } catch (e) {
    conn.online = false
    conn.lastFailAt = Date.now()
    if (e && e.name === 'AbortError') throw new ApiError('timeout', '等待手机响应超时，连接可能中断')
    throw new ApiError('network', res ? '读取手机响应时连接中断，操作结果尚未确认' : '与手机的连接中断')
  } finally {
    if (timer) clearTimeout(timer)
  }
  conn.online = true

  let data = null
  if (text) { try { data = JSON.parse(text) } catch { data = null } }

  if (res.ok || allow.includes(res.status)) return { status: res.status, data: data || {} }

  if (res.status === 401) {
    if (!silentAuth) onUnauthorized()
    throw new ApiError('auth', (data && (data.error || data.message)) || '需要重新登录', { status: 401, data })
  }
  if (res.status === 429) throw new ApiError('rate', '尝试次数过多，请 5 分钟后再试', { status: 429, data })
  const msg = (data && (data.error || data.message)) || `请求失败（HTTP ${res.status}）`
  if (res.status === 403) throw new ApiError('forbidden', msg, { status: 403, data })
  throw new ApiError('http', msg, { status: res.status, data })
}

const enc = encodeURIComponent
const P = (id) => `/api/projects/${enc(id)}`

export const api = {
  login: (token) => request('POST', '/api/login', { token }, { silentAuth: true }),
  logout: () => request('POST', '/api/logout', undefined, { silentAuth: true }),
  status: () => request('GET', '/api/status').then((r) => r.data),
  projects: () => request('GET', '/api/projects').then((r) => r.data.projects || []),
  createProject: (body) => request('POST', '/api/projects', body).then((r) => r.data),
  updateProject: (id, body) => request('PUT', P(id), body).then((r) => r.data),
  deleteProject: (id) => request('DELETE', P(id)).then((r) => r.data),
  pause: (id) => request('POST', `${P(id)}/pause`).then((r) => r.data),
  resume: (id) => request('POST', `${P(id)}/resume`).then((r) => r.data),
  // 409 / 500 也带 outcome，一并交给调用方
  snap: (id) => request('POST', `${P(id)}/snap`, undefined, { timeout: 90000, allow: [409, 500] }),
  dates: (id) => request('GET', `${P(id)}/frames`).then((r) => r.data.dates || []),
  frames: (id, date) => request('GET', `${P(id)}/frames?date=${enc(date)}`).then((r) => r.data.frames || []),
  deleteFrame: (id, date, name) => request('DELETE', `${P(id)}/frames/${enc(date)}/${enc(name)}`).then((r) => r.data),
  videos: (id) => request('GET', `${P(id)}/videos`).then((r) => r.data),
  encode: (id) => request('POST', `${P(id)}/encode`, undefined, { timeout: 0 }).then((r) => r.data),
  upload: (name) => request('POST', `/api/videos/${enc(name)}/upload`, undefined, { timeout: 0 }).then((r) => r.data),
  logs: (tail = 200) => request('GET', `/api/logs?tail=${tail}`).then((r) => r.data.lines || []),
}

export const media = {
  latest: (id, bust = '') => `${P(id)}/latest.jpg${bust ? `?t=${bust}` : ''}`,
  thumb: (id, kind, date, name) => `${P(id)}/media/${enc(kind)}/${enc(date)}/${enc(name)}`,
  frame: (id, date, name) => `${P(id)}/media/frames/${enc(date)}/${enc(name)}`,
  frameDownload: (id, date, name) => `${P(id)}/media/frames/${enc(date)}/${enc(name)}?download=1`,
  video: (id, name) => `${P(id)}/media/videos/${enc(name)}`,
}

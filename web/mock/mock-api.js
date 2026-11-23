// 仅开发用：npm run dev:mock 时以假数据模拟 tlapsed 的接口，口令是 demo。
// 不会进入生产包。
const TOKEN = 'demo'
const SID = 'mock-session'

function pad(n) { return String(n).padStart(2, '0') }
function ymd(d) { return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}` }

function makeFrames(days, perDay, startH = 6, stepMin = 5) {
  const out = {}
  const now = new Date()
  for (let k = 0; k < days; k++) {
    const d = new Date(now); d.setDate(d.getDate() - k)
    const list = []
    for (let i = 0; i < perDay; i++) {
      const m = startH * 60 + i * stepMin
      const name = `${pad(Math.floor(m / 60) % 24)}${pad(m % 60)}${pad((i * 7) % 60)}.jpg`
      list.push({ name, label: `${name.slice(0, 2)}:${name.slice(2, 4)}:${name.slice(4, 6)}`, kind: 'thumbs', bytes: 640000 + ((i * 7919) % 90000) })
    }
    out[ymd(d)] = list.reverse()
  }
  return out
}

const state = {
  sessions: new Set(),
  fails: 0,
  projects: [
    {
      id: 'mungbean', name: '绿豆发芽', enabled: false,
      capture: { interval: 300, resolution: '1920x1440', orientation: 'portrait', settleSeconds: 1.5, jpegQuality: 0.85, lockFocus: true, lockExposure: true, lockWhiteBalance: true, nightSkip: { enabled: true, from: '22:00', to: '06:00', brightness: 0.08 } },
      encode: { every: 'daily', at: '23:30', mode: 'cumulative', fps: 30, targetDuration: 30 },
      cleanup: { keepFramesDays: 14 }, upload: ['telegram'],
      state: { frameCount: 412, lastError: '' },
    },
    {
      id: 'ants', name: '蚂蚁工坊', enabled: false,
      capture: { interval: 60, resolution: '1440x1080', orientation: 'landscapeHomeRight', settleSeconds: 1, jpegQuality: 0.8, shutterSound: false, lockFocus: true, lockExposure: false, lockWhiteBalance: true, nightSkip: true },
      encode: { every: 'daily', at: '0:10', mode: 'daily', fps: 24 },
      cleanup: { keepFramesDays: 7 }, upload: [],
      state: { frameCount: 0, lastError: '摄像头被系统收回（mediaserverd），这一张没有保存' },
    },
  ],
  frames: { mungbean: makeFrames(4, 180), ants: {} },
  videos: { mungbean: [{ name: 'mungbean_20261112_cumulative.mp4' }], ants: [] },
  logs: [],
}
const started = Date.now()
function log(lv, msg) {
  const d = new Date()
  state.logs.push(`${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())} [${lv}] ${msg}`)
  if (state.logs.length > 400) state.logs.shift()
}
log('info', 'tlapsed 0.3.1 启动，jetsam 上限 96MB（活动/不活动，致命）')
log('info', '监听 192.0.2.20:8080（演示地址）')
log('info', 'mungbean 手动拍照：打开摄像头')
log('info', 'mungbean 已关闭摄像头')
log('info', 'mungbean 方向 portrait 尺寸=1440x1920，已保存照片 frames/20261112/230350.jpg')
log('warn', 'ants 这版系统没有快门声开关')
log('error', 'ants 拍照失败：摄像头被系统收回')

function svg(seed, label, w = 300, h = 400) {
  let x = 0
  for (const c of seed) x = (x * 31 + c.charCodeAt(0)) >>> 0
  const hue = x % 360
  const t = (x % 1000) / 1000
  const sun = 40 + t * 220
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 300 400">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="hsl(${hue},45%,${18 + t * 30}%)"/><stop offset="1" stop-color="hsl(${(hue + 40) % 360},35%,8%)"/></linearGradient>
<radialGradient id="s" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="#ffe9b0"/><stop offset="1" stop-color="#ffe9b0" stop-opacity="0"/></radialGradient></defs>
<rect width="300" height="400" fill="url(#g)"/><circle cx="${sun}" cy="${120 - t * 40}" r="70" fill="url(#s)" opacity=".7"/>
<path d="M0 300 Q 80 ${250 - t * 30} 150 290 T 300 ${280 - t * 20} V400 H0z" fill="#0b0b0b" opacity=".85"/>
<g fill="#7ec27a" opacity=".9"><path d="M150 300 C 148 ${260 - t * 60} 140 ${230 - t * 80} 132 ${210 - t * 90}" stroke="#7ec27a" stroke-width="3" fill="none"/><ellipse cx="${132}" cy="${206 - t * 90}" rx="10" ry="6"/></g>
<text x="12" y="388" fill="#ffffffaa" font-family="monospace" font-size="14">${label}</text></svg>`
}

function send(res, code, obj, headers = {}) {
  res.statusCode = code
  res.setHeader('Content-Type', 'application/json; charset=utf-8')
  for (const [k, v] of Object.entries(headers)) res.setHeader(k, v)
  res.end(JSON.stringify(obj))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function body(req) {
  let s = ''
  for await (const c of req) s += c
  return s ? JSON.parse(s) : {}
}
function merge(a, b) {
  for (const [k, v] of Object.entries(b)) {
    if (v === null) delete a[k]
    else if (v && typeof v === 'object' && !Array.isArray(v) && a[k] && typeof a[k] === 'object' && !Array.isArray(a[k])) merge(a[k], v)
    else a[k] = v
  }
  return a
}

export function mockApi() {
  return {
    name: 'tlapse-mock-api',
    configureServer(server) {
      server.middlewares.use(async (req, res, next) => {
        const url = new URL(req.url, 'http://x')
        const p = url.pathname
        if (!p.startsWith('/api/')) return next()
        await sleep(120 + Math.random() * 200)
        const m = req.method
        if (m !== 'GET' && m !== 'HEAD' && req.headers['x-tlapse-request'] !== '1') return send(res, 403, { error: '缺少 X-Tlapse-Request 请求头' })

        if (p === '/api/login' && m === 'POST') {
          const b = await body(req)
          if (state.fails >= 8) return send(res, 429, { error: '尝试次数过多' })
          if (b.token !== TOKEN) { state.fails++; return send(res, 401, { error: '口令错误' }) }
          state.fails = 0; state.sessions.add(SID)
          return send(res, 200, { ok: true }, { 'Set-Cookie': `tlapse_session=${SID}; HttpOnly; SameSite=Strict; Path=/; Max-Age=43200` })
        }
        const authed = (req.headers.cookie || '').includes(`tlapse_session=${SID}`) && state.sessions.has(SID)
        if (!authed) return send(res, 401, { error: '需要登录' })
        if (p === '/api/logout') { state.sessions.delete(SID); return send(res, 200, { ok: true }) }

        if (p === '/api/status') {
          const total = Object.values(state.frames).reduce((s, d) => s + Object.values(d).reduce((a, l) => a + l.length, 0), 0)
          const free = 6.4 * 1024 ** 3 - total * 680000
          return send(res, 200, {
            version: '0.3.1', pid: 4123, uptimeSeconds: Math.floor((Date.now() - started) / 1000) + 3 * 86400 + 5000, startedAt: new Date(Date.now() - 3 * 86400000).toISOString(),
            freeText: `${(free / 1024 ** 3).toFixed(1)} GB`, freeBytes: free, minFreeGB: 1,
            listeners: ['192.0.2.20:8080', '198.51.100.20:8080'], projectCount: state.projects.length, enabledCount: state.projects.filter((x) => x.enabled).length,
            battery: { percent: 86, charging: true, temperatureC: 31.4 }, storageRoot: '/var/mobile/Timelapse',
            features: { capture: true, encode: true, upload: true, cleanup: true },
          })
        }
        if (p === '/api/logs') return send(res, 200, { lines: state.logs.slice(-Math.min(400, +url.searchParams.get('tail') || 200)) })
        if (p === '/api/projects' && m === 'GET') return send(res, 200, { projects: state.projects })
        if (p === '/api/projects' && m === 'POST') {
          const b = await body(req)
          if (state.projects.some((x) => x.id === b.id)) return send(res, 409, { error: 'id 已存在' })
          const np = merge({ id: b.id, enabled: false, capture: {}, encode: {}, cleanup: {}, upload: [], state: { frameCount: 0 } }, b)
          state.projects.push(np); state.frames[b.id] = {}; state.videos[b.id] = []
          log('info', `新建项目 ${b.id}`)
          return send(res, 200, np)
        }
        const vm = /^\/api\/videos\/([^/]+)\/upload$/.exec(p)
        if (vm) { await sleep(1500); log('info', `上传 ${decodeURIComponent(vm[1])}：没有启用的上传目标`); return send(res, 200, { ok: false, message: '没有可用的上传目标：config.json 里 uploads 没有启用的账号' }) }

        const pm = /^\/api\/projects\/([^/]+)(\/.*)?$/.exec(p)
        if (!pm) return send(res, 404, { error: '没有这个接口' })
        const id = decodeURIComponent(pm[1])
        const rest = pm[2] || ''
        const proj = state.projects.find((x) => x.id === id)
        if (!proj) return send(res, 404, { error: '没有这个项目' })
        const fr = state.frames[id]

        if (rest === '' && m === 'PUT') { const b = await body(req); merge(proj, b); log('info', `更新项目 ${id}：${Object.keys(b).join(', ')}`); return send(res, 200, proj) }
        if (rest === '' && m === 'DELETE') { state.projects = state.projects.filter((x) => x.id !== id); return send(res, 200, { deleted: true, keptFiles: true }) }
        if (rest === '/pause') { proj.enabled = false; return send(res, 200, { ok: true }) }
        if (rest === '/resume') { proj.enabled = true; return send(res, 200, { ok: true }) }
        if (rest === '/snap') {
          log('info', `${id} 手动拍照：打开摄像头`)
          await sleep(2600)
          const d = new Date(); const key = ymd(d)
          const name = `${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}.jpg`
          ;(fr[key] ||= []).unshift({ name, label: `${name.slice(0, 2)}:${name.slice(2, 4)}:${name.slice(4, 6)}`, kind: 'thumbs', bytes: 686000 })
          log('info', `${id} 已关闭摄像头`)
          log('info', `${id} 方向 portrait 尺寸=1440x1920，已保存照片 frames/${key}/${name}`)
          return send(res, 200, { outcome: 'saved', message: '已保存照片', relativePath: `projects/${id}/frames/${key}/${name}`, width: 1440, height: 1920 })
        }
        if (rest === '/frames' && m === 'GET') {
          const date = url.searchParams.get('date')
          const dates = Object.keys(fr).filter((k) => fr[k].length).sort().reverse()
          if (!date) return send(res, 200, { dates })
          return send(res, 200, { date, frames: fr[date] || [] })
        }
        const dm = /^\/frames\/(\d{8})\/([^/]+)$/.exec(rest)
        if (dm && m === 'DELETE') {
          const list = fr[dm[1]] || []; const i = list.findIndex((f) => f.name === decodeURIComponent(dm[2]))
          if (i < 0) return send(res, 404, { error: '照片不存在' })
          list.splice(i, 1); return send(res, 200, { deleted: true, removed: 2 })
        }
        if (rest === '/latest.jpg') {
          const k = Object.keys(fr).filter((x) => fr[x].length).sort().pop()
          if (!k) return send(res, 404, { error: '没有照片' })
          res.setHeader('Content-Type', 'image/svg+xml'); return res.end(svg(k + fr[k][0].name, `${k} ${fr[k][0].label}`, 600, 800))
        }
        const mm = /^\/media\/(thumbs|frames)\/(\d{8})\/([^/]+)$/.exec(rest)
        if (mm) {
          const n = decodeURIComponent(mm[3])
          if (url.searchParams.get('download')) res.setHeader('Content-Disposition', `attachment; filename="${n}"`)
          res.setHeader('Content-Type', 'image/svg+xml')
          if (mm[1] === 'frames') await sleep(500)
          return res.end(svg(mm[2] + n, `${mm[2]} ${n}`, mm[1] === 'frames' ? 1440 : 300, mm[1] === 'frames' ? 1920 : 400))
        }
        if (rest === '/videos') return send(res, 200, { videos: state.videos[id] || [], encodeEnabled: true })
        if (rest === '/encode') {
          const n = Object.values(fr).reduce((s, l) => s + l.length, 0)
          if (!n) return send(res, 409, { error: '没有照片可以合成' })
          await sleep(4000)
          const name = `${id}_${ymd(new Date())}_${proj.encode?.mode || 'daily'}.mp4`
          if (!state.videos[id].some((v) => v.name === name)) state.videos[id].push({ name })
          log('info', `${id} 已合成 ${name}，${n} 帧`)
          return send(res, 200, { ok: true, message: '已合成', relativePath: `projects/${id}/videos/${name}`, width: 1920, height: 1440, frames: n, removedFrames: 0 })
        }
        if (rest.startsWith('/media/videos/')) return send(res, 404, { error: '演示数据里没有视频文件' })
        return send(res, 404, { error: '没有这个接口' })
      })
    },
  }
}

import { reactive } from 'vue'
import { api } from './api.js'
import { toast, toastError, confirmDialog } from './store.js'

// 每个项目一个忙碌标记，按钮在请求期间停用，避免连点
export const busy = reactive({})
function setBusy(id, key, v) {
  if (!busy[id]) busy[id] = {}
  busy[id][key] = v
}
export const isBusy = (id, key) => !!(busy[id] && busy[id][key])

const SKIP_TONE = { saved: 'ok', skippedNight: 'warn', skippedDark: 'warn', skippedStorage: 'warn', failed: 'danger' }

/** 立刻拍一张。返回 outcome 对象，网络失败返回 null */
export async function snap(project) {
  const id = project.id
  if (isBusy(id, 'snap')) return null
  setBusy(id, 'snap', true)
  try {
    const { data } = await api.snap(id)
    const tone = SKIP_TONE[data.outcome] || 'info'
    let msg = data.message || data.outcome || '完成'
    if (data.outcome === 'saved' && data.width) msg += ` · ${data.width}×${data.height}`
    toast(msg, tone, 5000)
    return data
  } catch (e) {
    if (e.kind === 'network' || e.kind === 'timeout') {
      toast('连接在拍照过程中中断。照片可能还在手机上保存，稍后刷新看看，不要急着再拍。', 'warn', 8000)
    } else if (e.status === 503) {
      toast(e.message || '当前进程没有摄像头', 'danger', 6000)
    } else toastError(e)
    return null
  } finally {
    setBusy(id, 'snap', false)
  }
}

export async function togglePause(project) {
  const id = project.id
  setBusy(id, 'pause', true)
  try {
    if (project.enabled) { await api.pause(id); project.enabled = false; toast(`「${project.name || id}」已暂停定时拍摄`) }
    else { await api.resume(id); project.enabled = true; toast(`「${project.name || id}」开始按 ${project.capture?.interval ?? '—'} 秒间隔定时拍摄`, 'ok') }
  } catch (e) { toastError(e) } finally { setBusy(id, 'pause', false) }
}

/** 快门声开关：改完立刻保存，只发这一项 */
export async function setShutter(project, on) {
  const id = project.id
  const prev = project.capture?.shutterSound !== false
  if (!project.capture) project.capture = {}
  project.capture.shutterSound = on
  setBusy(id, 'shutter', true)
  try {
    await api.updateProject(id, { capture: { shutterSound: on } })
    toast(on ? '快门声已打开' : '已设置静音请求；不支持时会报错，不会回退有声', 'ok')
  } catch (e) {
    project.capture.shutterSound = prev
    toastError(e)
  } finally { setBusy(id, 'shutter', false) }
}

export async function removeProject(project) {
  const ok = await confirmDialog({
    title: `删除项目「${project.name || project.id}」？`,
    body: '只会把这个项目从配置里去掉。\n已经拍下的照片和合成的视频仍保留在手机的 /var/mobile/Timelapse/projects/' + project.id + '/ 下，不会被删除。',
    confirmText: '从配置中删除',
    tone: 'danger',
  })
  if (!ok) return false
  try {
    const r = await api.deleteProject(project.id)
    toast(r.keptFiles ? '项目已删除，文件仍保留在手机上' : '项目已删除', 'ok')
    return true
  } catch (e) { toastError(e); return false }
}

export const shutterOn = (p) => p?.capture?.shutterSound !== false

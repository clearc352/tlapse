<script setup>
import { ref, computed, onMounted, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { api, media } from '../lib/api.js'
import { toastError } from '../lib/store.js'
import { device, refreshDevice } from '../lib/device.js'
import { snap, togglePause, setShutter, removeProject, isBusy, shutterOn } from '../lib/actions.js'
import { interval, num, encodeEvery } from '../lib/format.js'
import PhotoLibrary from '../components/PhotoLibrary.vue'
import VideoPanel from '../components/VideoPanel.vue'
import Icon from '../components/Icon.vue'

const props = defineProps({ id: String })
const route = useRoute()
const router = useRouter()
const p = ref(null)
const missing = ref(false)
const bust = ref(Date.now())
const photoKey = ref(0)
const videoKey = ref(0)
const counts = ref({ days: null, videos: null })
const tab = computed({
  get: () => (route.query.tab === 'videos' ? 'videos' : 'photos'),
  set: (v) => router.replace({ query: { ...route.query, tab: v === 'photos' ? undefined : v } }),
})

let loadRequest = 0
async function load() {
  const id = props.id, request = ++loadRequest
  try {
    const list = await api.projects()
    if (id !== props.id || request !== loadRequest) return
    const found = list.find((x) => x.id === id)
    if (!found) { missing.value = true; return }
    p.value = found
  } catch (e) { if (id === props.id && request === loadRequest) toastError(e) }
}
onMounted(() => { load(); refreshDevice().catch(() => {}) })
watch(() => props.id, () => { p.value = null; missing.value = false; counts.value = { days: null, videos: null }; load() })

const snapping = computed(() => p.value && isBusy(p.value.id, 'snap'))
const canCapture = computed(() => device.data?.features?.capture !== false)
async function doSnap() {
  const project = p.value
  const r = await snap(project)
  if (project.id !== props.id) return
  if (r && r.outcome === 'saved') {
    bust.value = Date.now()
    if (p.value.state) p.value.state.frameCount = (p.value.state.frameCount || 0) + 1
    photoKey.value++
  }
}
async function doRemove() { if (await removeProject(p.value)) router.replace('/') }
function onPhotosChanged() { bust.value = Date.now() }
function onEncoded() { photoKey.value++; load() }

const ORI = { auto: '自动（重力）', raw: '相机原始', portrait: '竖屏 · Home 在下', portraitUpsideDown: '竖屏 · Home 在上', landscapeHomeRight: '横屏 · Home 在右', landscapeHomeLeft: '横屏 · Home 在左' }
const night = computed(() => {
  const n = p.value?.capture?.nightSkip
  if (!n) return '关闭'
  if (n === true) return '22:00–06:00'
  if (typeof n === 'object') return n.enabled === false ? '关闭' : `${n.from}–${n.to}${n.brightness > 0 ? ` · 亮度<${n.brightness}` : ''}`
  return '—'
})
const facts = computed(() => {
  const c = p.value?.capture || {}, e = p.value?.encode || {}
  return [
    ['间隔', interval(c.interval ?? 300)],
    ['分辨率', c.resolution || '1920x1440'],
    ['方向', ORI[c.orientation || 'auto'] || c.orientation],
    ['JPEG 质量', (c.jpegQuality ?? 0.85).toFixed(2)],
    ['夜间跳过', night.value],
    ['合成', `${encodeEvery(e.every)} ${e.at || '23:30'} · ${e.mode === 'cumulative' ? '累计' : '当天'} · ${e.fps || 30}fps${e.targetDuration ? ` · ${e.targetDuration}s` : ''}`],
    ['保留原图', `${p.value?.cleanup?.keepFramesDays ?? 14} 天`],
    ['上传', (p.value?.upload || []).length ? p.value.upload.join('、') : '不上传'],
  ]
})
</script>

<template>
  <div class="shell page">
    <div v-if="missing" class="empty"><p class="display">找不到项目「{{ id }}」</p><p>配置可能已删除，已拍文件仍在手机上</p><router-link to="/" class="btn" style="margin-top:16px">回到项目</router-link></div>
    <template v-else>
      <header class="head">
        <router-link to="/" class="btn ghost icon back" title="回到项目" aria-label="回到项目"><Icon name="arrowLeft" :size="20" /></router-link>
        <div class="grow project-title">
          <h1 class="display">{{ p?.name || id }}</h1>
          <p v-if="p" class="summary"><span class="dot" :class="{ paused: !p.enabled }"></span>{{ p.enabled ? '拍摄中' : '已暂停' }}<span>·</span>{{ interval(p.capture?.interval) }}<span>·</span>{{ num(p.state?.frameCount ?? 0) }} 张</p>
        </div>
        <div class="head-actions" v-if="p">
          <button class="btn ghost icon" :disabled="isBusy(id,'pause')" @click="togglePause(p)" :title="p.enabled ? '暂停拍摄' : '继续拍摄'" :aria-label="p.enabled ? '暂停拍摄' : '继续拍摄'"><Icon :name="p.enabled ? 'pause' : 'play'" :size="19" /></button>
          <router-link :to="{name:'edit',params:{id}}" class="btn ghost icon" title="编辑参数" aria-label="编辑参数"><Icon name="sliders" :size="19" /></router-link>
          <button class="btn solid icon capture" :disabled="snapping || !canCapture" @click="doSnap" :title="canCapture ? '拍一张' : '当前进程没有拍照能力'" aria-label="拍一张"><span v-if="snapping" class="spinner"></span><Icon v-else name="camera" :size="20" /></button>
        </div>
      </header>
      <div class="media-bar">
        <div class="tabs" aria-label="媒体类型">
          <button :aria-pressed="tab === 'photos'" :class="{on:tab === 'photos'}" @click="tab = 'photos'"><Icon name="image" />照片<span v-if="counts.days != null">{{ counts.days }} 天</span></button>
          <button :aria-pressed="tab === 'videos'" :class="{on:tab === 'videos'}" @click="tab = 'videos'"><Icon name="film" />视频<span v-if="counts.videos != null">{{ counts.videos }}</span></button>
        </div>
        <span v-if="snapping" class="muted capturing" role="status"><span class="spinner"></span>拍摄中…</span>
      </div>
      <p v-if="p?.state?.lastError" class="error" role="status"><Icon name="alert" />{{ p.state.lastError }}</p>
      <section v-if="p" class="content">
        <PhotoLibrary :key="id" v-show="tab === 'photos'" :project-id="id" :refresh-key="photoKey" @changed="onPhotosChanged" @count="counts.days = $event" />
        <VideoPanel :key="id" v-if="tab === 'videos'" :project="p" :refresh-key="videoKey" @encoded="onEncoded" @count="counts.videos = $event" />
      </section>
      <div v-else class="skeleton" style="height:400px"></div>
      <details v-if="p" class="parameters">
        <summary><Icon name="sliders" :size="15" />拍摄参数</summary>
        <div class="parameter-body">
          <div class="shutter"><span><Icon :name="shutterOn(p) ? 'bell' : 'bellOff'" /> 快门声</span><button class="switch" role="switch" :aria-checked="shutterOn(p)" :disabled="isBusy(id,'shutter')" @click="setShutter(p,!shutterOn(p))" aria-label="快门声"></button></div>
          <p v-if="!shutterOn(p)" class="hint">不支持静音时会报错，不会回退有声</p>
          <dl class="facts"><div v-for="[k,v] in facts" :key="k"><dt>{{ k }}</dt><dd>{{ v }}</dd></div></dl>
          <div class="row gap-8"><router-link :to="{name:'edit',params:{id}}" class="btn"><Icon name="sliders" />编辑</router-link><span class="grow"></span><button class="btn ghost danger" @click="doRemove"><Icon name="trash" />删除项目</button></div>
        </div>
      </details>
    </template>
  </div>
</template>
<style scoped>
.page { padding-top: 32px; } .head { display: flex; align-items: center; gap: 12px; margin-bottom: 30px; } .head h1 { font-size: clamp(24px,2.6vw,34px); overflow-wrap: anywhere; } .back { margin-left: -12px; }
.summary { display: flex; align-items: center; gap: 9px; color: var(--fg-muted); font-size: 10px; margin-top: 9px; flex-wrap: wrap; } .dot { width: 5px; height: 5px; border-radius: 50%; background: var(--ok); } .dot.paused { background: var(--fg-faint); }
.head-actions { display: flex; gap: 7px; flex-shrink: 0; } .capture { margin-left: 8px; }
.media-bar { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 18px; }
.tabs { display: flex; gap: 24px; } .tabs button { display: flex; align-items: center; gap: 8px; min-height: 44px; padding: 0; color: var(--fg-muted); border: 0; background: transparent; cursor: pointer; font-size: 12px; } .tabs button.on { color: var(--fg); font-weight: 700; } .tabs button>span { color: var(--fg-muted); font-weight: 400; font-size: 10px; } .capturing { display: flex; align-items: center; gap: 8px; font-size: 11px; }
.content { min-width: 0; } .error { display: flex; align-items: center; gap: 10px; padding: 12px 16px; background: var(--danger-soft); color: var(--danger); border-radius: 8px; margin-bottom: 18px; font-size: 12px; }
.parameters { margin-top: 24px; border-top: 1px solid var(--rule); padding-top: 20px; font-size: 12px; color: var(--fg-muted); } .parameters summary { display: flex; align-items: center; gap: 8px; cursor: pointer; width: max-content; min-height: 44px; } .parameter-body { max-width: 680px; margin-top: 12px; }
.shutter { display: flex; align-items: center; justify-content: space-between; padding: 12px 0; } .shutter>span { display: flex; align-items: center; gap: 8px; color: var(--fg); }
.facts { margin: 16px 0 24px; } .facts div { display: flex; gap: 20px; border-top: 1px solid var(--rule); padding: 12px 0; } dt { flex-shrink: 0; } dd { margin: 0 0 0 auto; color: var(--fg); text-align: right; overflow-wrap: anywhere; }
@media (max-width: 680px) { .page { padding-top: 24px; } .head { gap: 4px; flex-wrap: wrap; margin-bottom: 18px; } .head h1 { font-size: 25px; } .project-title { min-width: 150px; } .head-actions { gap: 0; margin-left: auto; } .capture { margin-left: 4px; } .back { margin-left: -10px; } .summary { font-size: 9px; } }
</style>

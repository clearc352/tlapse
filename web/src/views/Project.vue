<script setup>
import { ref, computed, onMounted, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { api, media } from '../lib/api.js'
import { toastError } from '../lib/store.js'
import { device, refreshDevice } from '../lib/device.js'
import { snap, togglePause, setShutter, removeProject, isBusy, shutterOn } from '../lib/actions.js'
import { interval, num, encodeEvery } from '../lib/format.js'
import SafeImg from '../components/SafeImg.vue'
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
    <div v-if="missing" class="empty" style="margin-top: 80px">
      <p class="display">找不到项目「{{ id }}」</p>
      <p>它可能已经从配置里删除了，已拍的文件仍在手机上。</p>
      <router-link to="/" class="btn" style="margin-top: 16px">回到总览</router-link>
    </div>

    <template v-else>
      <nav class="crumb">
        <router-link to="/" class="back"><Icon name="arrowLeft" size="14" />总览</router-link>
      </nav>

      <header class="head rise">
        <div class="grow">
          <span class="eyebrow mono">{{ id }}</span>
          <h1 class="display h-xl">{{ p?.name || id }}</h1>
          <div class="pills" v-if="p">
            <span class="pill" :class="p.enabled ? 'live' : 'paused'"><span class="dot"></span>{{ p.enabled ? '定时拍摄中' : '已暂停' }}</span>
            <span class="pill">{{ interval(p.capture?.interval) }}</span>
            <span class="pill num">累计 {{ num(p.state?.frameCount ?? 0) }} 张</span>
            <span v-if="!shutterOn(p)" class="pill accent"><Icon name="bellOff" size="12" />快门静音</span>
          </div>
        </div>
        <div class="head-actions" v-if="p">
          <router-link :to="{ name: 'edit', params: { id } }" class="btn"><Icon name="sliders" />编辑参数</router-link>
          <button class="btn ghost icon del" title="删除项目" @click="doRemove"><Icon name="trash" /></button>
        </div>
      </header>

      <div class="layout">
        <!-- 左：控制 -->
        <aside class="ctrl">
          <div class="sticky">
            <figure class="latest panel">
              <div class="img">
                <SafeImg v-if="p" :src="media.latest(id, bust)" quiet fit="contain" eager :alt="`${p.name} 最新一张`">
                  <template #empty><span class="noshot"><Icon name="image" size="28" />还没有照片</span></template>
                </SafeImg>
                <div v-if="snapping" class="flash"><span class="spinner"></span>对焦、拍摄中，通常要几秒…</div>
              </div>
              <figcaption class="cap"><span class="eyebrow">最新一张</span></figcaption>
            </figure>

            <div class="act" v-if="p">
              <button class="btn foil lg wide" :disabled="snapping || !canCapture" @click="doSnap">
                <span v-if="snapping" class="spinner"></span><Icon v-else name="camera" size="18" />{{ snapping ? '拍摄中…' : '拍一张' }}
              </button>
              <button class="btn lg wide" :disabled="isBusy(id, 'pause')" @click="togglePause(p)">
                <Icon :name="p.enabled ? 'pause' : 'play'" />{{ p.enabled ? '暂停定时拍摄' : '开始定时拍摄' }}
              </button>
              <p class="note faint">{{ p.enabled ? '手动拍照不影响定时队列。' : '项目暂停中，手动拍照照样可用。' }}</p>
            </div>

            <div class="shutter panel" v-if="p">
              <div class="grow">
                <div class="row gap-8"><Icon :name="shutterOn(p) ? 'bell' : 'bellOff'" /><b>快门声</b></div>
                <p class="faint">{{ shutterOn(p) ? '拍照时会发出系统快门声' : '只请求静音拍摄；不支持或未获授权时会报错，不会回退有声。' }}</p>
              </div>
              <button class="switch" role="switch" :aria-checked="shutterOn(p)" :disabled="isBusy(id, 'shutter')" @click="setShutter(p, !shutterOn(p))" aria-label="快门声"></button>
            </div>

            <p v-if="p?.state?.lastError" class="error"><Icon name="alert" size="14" /><span><b>最近错误</b><br />{{ p.state.lastError }}</span></p>

            <dl class="facts" v-if="p">
              <div v-for="[k, v] in facts" :key="k"><dt>{{ k }}</dt><dd>{{ v }}</dd></div>
            </dl>
          </div>
        </aside>

        <!-- 右：照片 / 视频 -->
        <section class="content">
          <div class="tabs" role="tablist">
            <button role="tab" :aria-selected="tab === 'photos'" :class="{ on: tab === 'photos' }" @click="tab = 'photos'">
              <Icon name="image" />照片<span class="c" v-if="counts.days != null">{{ counts.days }} 天</span>
            </button>
            <button role="tab" :aria-selected="tab === 'videos'" :class="{ on: tab === 'videos' }" @click="tab = 'videos'">
              <Icon name="film" />视频<span class="c" v-if="counts.videos != null">{{ counts.videos }}</span>
            </button>
          </div>
          <div v-if="p">
            <PhotoLibrary :key="id" v-show="tab === 'photos'" :project-id="id" :refresh-key="photoKey" @changed="onPhotosChanged" @count="counts.days = $event" />
            <VideoPanel :key="id" v-if="tab === 'videos'" :project="p" :refresh-key="videoKey" @encoded="onEncoded" @count="counts.videos = $event" />
          </div>
          <div v-else class="skeleton" style="height: 400px"></div>
        </section>
      </div>
    </template>
  </div>
</template>

<style scoped>
.page { padding-top: 28px; }
.crumb { margin-bottom: 20px; }
.back { display: inline-flex; align-items: center; gap: 6px; font-size: 13.5px; color: var(--fg-muted); transition: color var(--dur-2); }
.back:hover { color: var(--fg); }
.head { display: flex; align-items: flex-end; gap: 24px; margin-bottom: 32px; }
.head h1 { margin: 10px 0 16px; }
.pills { display: flex; gap: 6px; flex-wrap: wrap; }
.head-actions { display: flex; gap: 8px; }
.del:hover { color: var(--danger); }
.layout { display: grid; grid-template-columns: minmax(280px, 360px) 1fr; gap: clamp(24px, 3vw, 48px); align-items: start; }
.ctrl, .content { min-width: 0; }
.sticky { position: sticky; top: calc(var(--topbar-h) + var(--frame) + 20px); display: flex; flex-direction: column; gap: 14px; }
.latest { overflow: hidden; }
.latest .img { position: relative; aspect-ratio: 3 / 4; max-height: 40vh; width: 100%; }
.cap { padding: 10px 14px; border-top: 1px solid var(--rule); }
.noshot { display: flex; flex-direction: column; align-items: center; gap: 8px; font-size: 13px; }
.flash { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; gap: 10px; padding: 16px; text-align: center; background: #ffffffc0; backdrop-filter: blur(4px); color: var(--fg); font-size: 14px; }
.act { display: flex; flex-direction: column; gap: 8px; }
.wide { width: 100%; }
.note { font-size: 12.5px; text-align: center; }
.shutter { display: flex; align-items: center; gap: 14px; padding: 14px 16px; }
.shutter b { font-weight: 500; color: var(--fg); font-size: 14px; }
.shutter p { font-size: 12.5px; margin-top: 4px; line-height: 1.5; }
.error { display: flex; gap: 8px; padding: 12px 14px; border-radius: var(--r-md); background: var(--danger-soft); color: var(--danger); font-size: 13px; line-height: 1.55; }
.error svg { flex: none; margin-top: 3px; }
.error b { font-weight: 600; }
.facts { margin: 4px 0 0; border-top: 1px solid var(--rule); }
.facts div { display: flex; justify-content: space-between; gap: 16px; padding: 9px 2px; border-bottom: 1px solid var(--rule); font-size: 13px; }
.facts dt { color: var(--fg-muted); flex: none; }
.facts dd { margin: 0; color: var(--fg); text-align: right; min-width: 0; overflow-wrap: anywhere; }
.tabs { display: flex; gap: 4px; margin-bottom: 18px; border-bottom: 1px solid var(--rule); }
.tabs button { position: relative; display: inline-flex; align-items: center; gap: 8px; height: 44px; padding: 0 14px; border: 0; background: none; color: var(--fg-muted); cursor: pointer; font-size: 15px; transition: color var(--dur-2); }
.tabs button:hover { color: var(--fg); }
.tabs button.on { color: var(--fg); }
.tabs button.on::after { content: ""; position: absolute; left: 10px; right: 10px; bottom: -1px; height: 2px; border-radius: 2px; background: linear-gradient(90deg in oklch, #b76dd7, #3b6ff6); }
.tabs .c { font-size: 12px; color: var(--fg-faint); }
@media (max-width: 900px) {
  .layout { grid-template-columns: 1fr; }
  .sticky { position: static; }
  .latest .img { aspect-ratio: 4 / 3; max-height: 46vh; }
  .facts { display: none; }
  .head { flex-direction: column; align-items: flex-start; }
}
</style>

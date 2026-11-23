<script setup>
import { ref, computed, watch, onBeforeUnmount } from 'vue'
import { media, api } from '../lib/api.js'
import { snap, togglePause, removeProject, isBusy, shutterOn } from '../lib/actions.js'
import { interval, num } from '../lib/format.js'
import { toastError } from '../lib/store.js'
import { device } from '../lib/device.js'
import SafeImg from './SafeImg.vue'
import Icon from './Icon.vue'
const props = defineProps({ project: Object, bust: Number, featured: Boolean })
const emit = defineEmits(['removed','snapped'])
const p = computed(() => props.project)
const localBust = ref(0), position = ref(1000), frames = ref(null), date = ref(''), previewLoading = ref(false)
let active = true, epoch = 0
onBeforeUnmount(() => { active = false; epoch++ })
watch(() => [props.bust,props.project.id], () => { epoch++; frames.value = null; date.value = ''; position.value = 1000; previewLoading.value = false })
const current = computed(() => frames.value?.[Math.round(position.value / 1000 * (frames.value.length - 1))])
const image = computed(() => current.value ? media.thumb(p.value.id,current.value.kind,date.value,current.value.name) : media.latest(p.value.id,`${props.bust}-${localBust.value}`))
async function loadPreview() {
  if (frames.value !== null || previewLoading.value) return
  const id = p.value.id, key = epoch
  previewLoading.value = true
  try {
    const days = await api.dates(id)
    const day = days[0]
    const list = day ? await api.frames(id,day) : []
    if (!active || key !== epoch) return
    date.value = day || ''; frames.value = [...list].sort((a,b) => a.name.localeCompare(b.name))
  } catch (e) { if (active && key === epoch) toastError(e) }
  finally { if (active && key === epoch) previewLoading.value = false }
}
const snapping = computed(() => isBusy(p.value.id,'snap'))
const canCapture = computed(() => device.data?.features?.capture !== false)
async function doSnap() {
  const r = await snap(p.value)
  if (r?.outcome === 'saved') { localBust.value = Date.now(); if (p.value.state) p.value.state.frameCount = (p.value.state.frameCount || 0) + 1; emit('snapped') }
}
async function doRemove() { if (await removeProject(p.value)) emit('removed',p.value.id) }
</script>
<template>
  <article class="card" :class="{ featured }">
    <div class="shot">
      <router-link :to="{ name:'project',params:{ id:p.id } }" class="image-link" :aria-label="`打开 ${p.name || p.id}`">
        <SafeImg :src="image" quiet :alt="current ? current.label : (p.name || p.id) + ' 最新一张'"><template #empty><span class="noshot"><Icon name="image" :size="26" /><span>暂无画面</span></span></template></SafeImg>
      </router-link>
      <span class="state" :class="{ paused: !p.enabled }" :title="p.enabled ? '定时拍摄中' : '已暂停'"><span></span>{{ p.enabled ? '拍摄中' : '暂停' }}</span>
      <span v-if="!shutterOn(p)" class="silent" title="静音拍摄" aria-label="静音拍摄"><Icon name="bellOff" :size="15" /></span>
      <div v-if="snapping" class="flash" role="status"><span class="spinner"></span>拍摄中…</div>
    </div>
    <div class="scrub">
      <input type="range" min="0" max="1000" step="1" v-model.number="position" :aria-label="`${p.name || p.id} 照片预览`" :aria-valuetext="previewLoading ? '加载中' : current ? current.label : frames?.length === 0 ? '暂无照片' : '最新一张，拖动预览'" @pointerdown="loadPreview" @focus="loadPreview" @input="loadPreview" />
      <span class="scrub-time">{{ previewLoading ? '…' : current?.label || (frames?.length === 0 ? '暂无照片' : '最新') }}</span>
    </div>
    <div class="meta"><router-link :to="{ name:'project',params:{ id:p.id } }"><h2>{{ p.name || p.id }}</h2></router-link><span class="muted">{{ interval(p.capture?.interval) }}<span class="divider">/</span>{{ num(p.state?.frameCount ?? 0) }} 张</span></div>
    <div class="actions">
      <button class="btn ghost icon" :disabled="snapping || !canCapture" @click="doSnap" aria-label="拍一张" :title="canCapture ? '拍一张' : '当前进程没有拍照能力'"><span v-if="snapping" class="spinner"></span><Icon v-else name="camera" :size="18" /></button>
      <button class="btn ghost icon" :disabled="isBusy(p.id,'pause')" @click="togglePause(p)" :aria-label="p.enabled ? '暂停拍摄' : '继续拍摄'" :title="p.enabled ? '暂停拍摄' : '继续拍摄'"><Icon :name="p.enabled ? 'pause' : 'play'" :size="18" /></button>
      <router-link :to="{ name:'project',params:{id:p.id},query:{tab:'videos'} }" class="btn ghost icon" title="视频" aria-label="视频"><Icon name="film" :size="18" /></router-link>
      <span class="grow"></span>
      <router-link :to="{ name:'edit',params:{id:p.id} }" class="btn ghost icon" title="编辑参数" aria-label="编辑参数"><Icon name="sliders" :size="18" /></router-link>
      <button class="btn ghost icon danger" title="删除项目" aria-label="删除项目" @click="doRemove"><Icon name="trash" :size="17" /></button>
    </div>
    <p v-if="p.state?.lastError" class="error"><Icon name="alert" :size="14" />{{ p.state.lastError }}</p>
  </article>
</template>
<style scoped>
.card { height: 100%; display: flex; flex-direction: column; min-width: 0; }
.shot { position: relative; overflow: hidden; border-radius: 9px; flex: 1; min-height: 190px; aspect-ratio: 2.65; background: var(--wash); }
.featured .shot { aspect-ratio: .83; min-height: 390px; }
.image-link { position: absolute; inset: 0; } .image-link:focus-visible { outline-offset: -5px; border-radius: 9px; } .shot :deep(img) { transition: transform .5s var(--ease-out); } .image-link:hover :deep(img) { transform: scale(1.018); }
.noshot { display: flex; flex-direction: column; align-items: center; gap: 10px; font-size: 12px; }
.state { position: absolute; left: 14px; top: 14px; border-radius: 20px; background: #fafaf7ed; color: var(--ok); display: flex; align-items: center; gap: 7px; font-size: 10px; padding: 5px 10px; pointer-events: none; } .state>span { width: 5px; height: 5px; background: currentColor; border-radius: 50%; } .state.paused { color: var(--fg-muted); }
.silent { position: absolute; right: 14px; top: 16px; color: white; filter: drop-shadow(0 1px 3px #0008); pointer-events: none; }
.flash { position: absolute; inset: 0; background: #fafaf7b8; display: flex; align-items: center; justify-content: center; gap: 10px; font-size: 13px; }
.scrub { display: flex; align-items: center; gap: 14px; height: 44px; }
.scrub input { flex: 1; min-width: 0; accent-color: var(--fg); cursor: ew-resize; height: 32px; }
.scrub-time { font-size: 10px; color: var(--fg-muted); min-width: 48px; text-align: right; }
.meta { display: flex; align-items: center; justify-content: space-between; gap: 12px; } .meta h2 { color: var(--fg); font-size: 18px; line-height: 1.3; font-weight: 700; letter-spacing: -.025em; overflow-wrap: anywhere; } .meta .muted { font-size: 10px; flex-shrink: 0; } .divider { margin: 0 8px; color: var(--border-strong); }
.actions { display: flex; gap: 2px; margin-top: 6px; } .actions .btn { color: var(--fg-muted); } .actions .danger:hover { color: var(--danger); }
.error { display: flex; align-items: flex-start; gap: 8px; color: var(--danger); font-size: 12px; margin-top: 8px; } .error svg { flex: none; margin-top: 2px; }
@media (max-width: 680px) { .shot { aspect-ratio: 1.5; min-height: 0; } .featured .shot { aspect-ratio: 1.1; min-height: 0; } }
</style>

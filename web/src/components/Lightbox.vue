<script setup>
// 大图：先显示缩略图占位，原图到了再淡入。只预读下一张原图。
import { ref, computed, watch, onMounted, onBeforeUnmount } from 'vue'
import { media } from '../lib/api.js'
import { dateLong, bytes } from '../lib/format.js'
import Icon from './Icon.vue'

const props = defineProps({ projectId: String, date: String, frames: Array, index: Number, deleting: Boolean })
const emit = defineEmits(['close', 'update:index', 'delete'])

const f = computed(() => props.frames[props.index])
const state = ref('loading')
const nonce = ref(0)
const fullUrl = computed(() => f.value ? media.frame(props.projectId, props.date, f.value.name) + (nonce.value ? `?r=${nonce.value}` : '') : '')
const thumbUrl = computed(() => f.value ? media.thumb(props.projectId, f.value.kind, props.date, f.value.name) : '')
watch(() => f.value?.name, () => { state.value = 'loading'; nonce.value = 0; preloadNext() })

let pre
function preloadNext() {
  const n = props.frames[props.index + 1]
  if (!n) return
  pre = new Image()
  pre.src = media.frame(props.projectId, props.date, n.name)
}
const go = (d) => {
  const i = props.index + d
  if (i >= 0 && i < props.frames.length) emit('update:index', i)
}
function onKey(e) {
  if (e.target && /INPUT|TEXTAREA|SELECT/.test(e.target.tagName)) return
  if (e.key === 'Escape') emit('close')
  else if (e.key === 'ArrowLeft') go(-1)
  else if (e.key === 'ArrowRight') go(1)
  else if (e.key === 'Delete' || e.key === 'Backspace') emit('delete', f.value)
}
let tx = 0
const onTouchStart = (e) => { tx = e.touches[0].clientX }
const onTouchEnd = (e) => { const dx = e.changedTouches[0].clientX - tx; if (Math.abs(dx) > 50) go(dx < 0 ? 1 : -1) }
onMounted(() => { document.addEventListener('keydown', onKey); document.body.style.overflow = 'hidden'; preloadNext() })
onBeforeUnmount(() => { document.removeEventListener('keydown', onKey); document.body.style.overflow = '' })
</script>

<template>
  <Teleport to="body">
  <div class="lb" role="dialog" aria-modal="true" aria-label="查看原图" @touchstart.passive="onTouchStart" @touchend.passive="onTouchEnd">
    <header class="bar">
      <div class="info">
        <span class="display t">{{ f?.label }}</span>
        <span class="muted">{{ dateLong(date) }}</span>
        <span class="faint num">{{ index + 1 }} / {{ frames.length }}</span>
        <span class="faint" v-if="f?.bytes">{{ bytes(f.bytes) }}</span>
      </div>
      <div class="tools">
        <a v-if="f" class="btn sm" :href="media.frameDownload(projectId, date, f.name)" download><Icon name="download" size="14" />下载原图</a>
        <button class="btn sm danger" :disabled="deleting" @click="emit('delete', f)"><span v-if="deleting" class="spinner"></span><Icon v-else name="trash" size="14" />删除</button>
        <button class="btn sm icon ghost" title="关闭（Esc）" @click="emit('close')"><Icon name="close" /></button>
      </div>
    </header>

    <div class="stage" @click.self="emit('close')">
      <button class="nav prev" :disabled="index <= 0" @click="go(-1)" title="上一张（←，较新）"><Icon name="chevronLeft" size="22" /></button>
      <div class="frame" v-if="f">
        <img class="ph" :src="thumbUrl" alt="" aria-hidden="true" />
        <img v-show="state !== 'error'" class="full" :class="{ in: state === 'ok' }" :src="fullUrl" :alt="`${date} ${f.label}`" @load="state = 'ok'" @error="state = 'error'" draggable="false" />
        <div v-if="state === 'loading'" class="loading"><span class="spinner"></span>正在从手机读取原图…</div>
        <div v-if="state === 'error'" class="loading err">原图没有载入<button class="btn sm" @click="nonce++; state = 'loading'">重新载入</button></div>
      </div>
      <button class="nav next" :disabled="index >= frames.length - 1" @click="go(1)" title="下一张（→，较早）"><Icon name="chevronRight" size="22" /></button>
    </div>
    <p class="hint faint">← → 翻页 · Delete 删除 · Esc 关闭</p>
  </div>
  </Teleport>
</template>

<style scoped>
.lb {
  /* 看片保持深色暗房：照片在深底上更易判断曝光 */
  --fg: #fff; --fg-head: #fff; --fg-body: #ffffffcc; --fg-muted: #ffffff80; --fg-faint: #ffffff59;
  --border: #ffffff26; --border-strong: #ffffff40; --rule: #2a2a2a; --surface: #f4f3ef;
  color: var(--fg-body); color-scheme: dark;
  position: fixed; inset: 0; z-index: 950; background: #131313f5; backdrop-filter: blur(10px); display: flex; flex-direction: column; animation: fadein var(--dur-3) var(--ease-out); }
@keyframes fadein { from { opacity: 0; } }
.lb .btn { background: #ffffff12; border-color: #ffffff26; color: #fff; box-shadow: none; }
.lb .btn:hover:not(:disabled) { background: #ffffff21; border-color: #ffffff4d; box-shadow: none; }
.lb .btn.danger { color: #ff9c97; border-color: #ff9c9740; }
.bar { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 14px var(--gutter); border-bottom: 1px solid var(--rule); flex-wrap: wrap; }
.info { display: flex; align-items: baseline; gap: 14px; flex-wrap: wrap; font-size: 13.5px; }
.info .t { font-size: 28px; color: var(--fg); }
.tools { display: flex; gap: 8px; }
.stage { flex: 1; min-height: 0; overflow: hidden; display: grid; grid-template-columns: 64px 1fr 64px; align-items: center; padding: 16px 8px; }
.frame { position: relative; height: 100%; display: grid; place-items: center; min-width: 0; }
.frame img { grid-area: 1 / 1; width: 100%; height: calc(100dvh - 150px); object-fit: contain; }
.ph { filter: blur(10px) brightness(.6); }
.full { opacity: 0; transition: opacity var(--dur-4) var(--ease-out); }
.full.in { opacity: 1; }
.frame:has(.full.in) .ph { visibility: hidden; }
.loading { position: absolute; bottom: 16px; left: 50%; transform: translateX(-50%); display: flex; align-items: center; gap: 10px; padding: 8px 14px; border-radius: var(--r-full); background: #131313d9; border: 1px solid var(--border); font-size: 13px; color: var(--fg-body); white-space: nowrap; }
.loading.err { color: var(--danger); }
.nav { width: 48px; height: 48px; border-radius: 50%; border: 1px solid var(--border); background: #ffffff08; color: var(--fg); display: grid; place-items: center; cursor: pointer; justify-self: center; transition: background var(--dur-2); }
.nav:hover:not(:disabled) { background: #ffffff1a; }
.nav:disabled { opacity: .2; cursor: default; }
.hint { text-align: center; font-size: 12px; padding-bottom: 12px; }
@media (max-width: 640px) { .stage { grid-template-columns: 1fr; } .nav { display: none; } .hint { display: none; } }
</style>

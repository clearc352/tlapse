<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from 'vue'
import Icon from './Icon.vue'
const props = defineProps<{ src: string; name: string }>()
const player = ref<HTMLVideoElement>()
const attempt = ref(0)
const state = ref<'loading' | 'ready' | 'error'>('loading')
let timer: ReturnType<typeof setTimeout> | undefined
function clearTimer() { if (timer) clearTimeout(timer); timer = undefined }
function failed() {
  clearTimer(); state.value = 'error'; player.value?.pause()
}
function arm() {
  clearTimer()
  if (state.value === 'error') return
  state.value = 'loading'
  timer = setTimeout(() => { if (document.hidden) arm(); else failed() }, 20000)
}
function ready(event: Event) {
  if (event.target !== player.value) return
  const v = player.value
  if (v && v.duration > 0 && v.readyState >= 1) { clearTimer(); state.value = 'ready' }
}
function waiting() { if (!player.value?.paused) arm() }
function retry() { attempt.value++; state.value = 'loading'; arm() }
watch(() => props.src, () => { attempt.value = 0; state.value = 'loading'; arm() }, { immediate: true })
onBeforeUnmount(clearTimer)
</script>
<template>
  <div class="video-player" :class="{ failed: state === 'error' }">
    <video ref="player" :key="src + ':' + attempt" :src="src + (attempt ? (src.includes('?') ? '&' : '?') + 'retry=' + attempt : '')" controls preload="metadata" playsinline :aria-label="name" @loadedmetadata="ready" @durationchange="ready" @canplay="ready" @playing="ready" @timeupdate="ready" @waiting="waiting" @stalled="waiting" @error="failed"></video>
    <p v-if="state === 'loading'" class="loading" role="status"><span class="spinner"></span>正在读取视频…</p>
    <div v-if="state === 'error'" class="video-error" role="alert">
      <Icon name="film" :size="30" /><p>视频无法加载</p><span>请检查连接、文件或编码格式</span>
      <div class="row gap-8"><button class="btn" @click="retry"><Icon name="refresh" />重试</button><a :href="src" :download="name" class="btn ghost"><Icon name="download" />下载</a></div>
    </div>
  </div>
</template>
<style scoped>
.video-player { position: relative; background: #181d17; min-height: 220px; }
video { width: 100%; max-height: 62vh; margin: 0 auto; min-height: 220px; }
.failed video { visibility: hidden; }
.loading { position: absolute; top: 20px; left: 50%; transform: translateX(-50%); display: flex; align-items: center; gap: 8px; font-size: 12px; color: #fff; background: #242820cc; padding: 8px 14px; border-radius: 20px; pointer-events: none; white-space: nowrap; }
.video-error { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 12px; padding: 28px; color: var(--fg); background: var(--wash); }
.video-error p { font-weight: 700; font-size: 16px; } .video-error>span { color: var(--fg-muted); font-size: 12px; } .video-error .row { margin-top: 5px; }
</style>

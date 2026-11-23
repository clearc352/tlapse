<script setup>
import { ref, computed } from 'vue'
import { useRouter } from 'vue-router'
import { media } from '../lib/api.js'
import { snap, togglePause, removeProject, isBusy, shutterOn } from '../lib/actions.js'
import { interval, num, encodeEvery } from '../lib/format.js'
import { device } from '../lib/device.js'
import SafeImg from './SafeImg.vue'
import Icon from './Icon.vue'

const props = defineProps({ project: Object, bust: Number })
const emit = defineEmits(['removed', 'snapped'])
const router = useRouter()
const p = computed(() => props.project)
const localBust = ref(0)
const imgKey = computed(() => `${props.bust}-${localBust.value}`)
const snapping = computed(() => isBusy(p.value.id, 'snap'))
const canCapture = computed(() => device.data?.features?.capture !== false)

async function doSnap() {
  const r = await snap(p.value)
  if (r && r.outcome === 'saved') {
    localBust.value = Date.now()
    if (p.value.state) p.value.state.frameCount = (p.value.state.frameCount || 0) + 1
    emit('snapped')
  }
}
async function doRemove() { if (await removeProject(p.value)) emit('removed', p.value.id) }
const open = () => router.push({ name: 'project', params: { id: p.value.id } })
</script>

<template>
  <article class="card panel">
    <div class="shot" @click="open" role="link" tabindex="0" @keydown.enter="open" :aria-label="`打开 ${p.name}`">
      <SafeImg :src="media.latest(p.id, imgKey)" quiet :alt="`${p.name} 最新一张`">
        <template #empty><span class="noshot"><Icon name="image" size="28" /><span>还没有照片</span></span></template>
      </SafeImg>
      <div class="badges">
        <span class="pill" :class="p.enabled ? 'live' : 'paused'"><span class="dot"></span>{{ p.enabled ? '定时拍摄中' : '已暂停' }}</span>
        <span v-if="!shutterOn(p)" class="pill accent" title="本项目请求静音拍摄；不支持时会报错"><Icon name="bellOff" size="12" />静音</span>
      </div>
      <div v-if="snapping" class="flash"><span class="spinner"></span>对焦、拍摄中…</div>
    </div>

    <div class="body">
      <div class="title-row" @click="open">
        <h3 class="display">{{ p.name || p.id }}</h3>
        <span class="mono faint id">{{ p.id }}</span>
      </div>
      <dl class="stats">
        <div><dt>间隔</dt><dd>{{ interval(p.capture?.interval) }}</dd></div>
        <div><dt>累计</dt><dd class="num">{{ num(p.state?.frameCount ?? 0) }} 张</dd></div>
        <div><dt>合成</dt><dd>{{ encodeEvery(p.encode?.every) }} {{ p.encode?.at || '' }}</dd></div>
      </dl>
      <p v-if="p.state?.lastError" class="error"><Icon name="alert" size="14" /><span>{{ p.state.lastError }}</span></p>
    </div>

    <div class="actions">
      <button class="btn foil" :disabled="snapping || !canCapture" @click="doSnap" :title="canCapture ? '暂停中也可以手动拍' : '当前进程没有拍照能力'">
        <span v-if="snapping" class="spinner"></span><Icon v-else name="camera" />{{ snapping ? '拍摄中' : '拍一张' }}
      </button>
      <button class="btn" :disabled="isBusy(p.id, 'pause')" @click="togglePause(p)">
        <Icon :name="p.enabled ? 'pause' : 'play'" />{{ p.enabled ? '暂停' : '继续' }}
      </button>
      <span class="grow"></span>
      <router-link :to="{ name: 'project', params: { id: p.id } }" class="btn ghost icon" title="照片与视频"><Icon name="image" /></router-link>
      <router-link :to="{ name: 'edit', params: { id: p.id } }" class="btn ghost icon" title="编辑参数"><Icon name="sliders" /></router-link>
      <button class="btn ghost icon del" title="删除项目" @click="doRemove"><Icon name="trash" /></button>
    </div>
  </article>
</template>

<style scoped>
.card { overflow: hidden; display: flex; flex-direction: column; transition: border-color var(--dur-3), transform var(--dur-4) var(--ease-out); }
.card:hover { border-color: var(--border-strong); box-shadow: var(--shadow-2); transform: translateY(-2px); }
.shot { position: relative; aspect-ratio: 4 / 3; cursor: pointer; overflow: hidden; }
.shot :deep(img) { transition: transform var(--dur-5) var(--ease-out), opacity var(--dur-4); }
.card:hover .shot :deep(img) { transform: scale(1.025); }
.noshot { display: flex; flex-direction: column; align-items: center; gap: 8px; font-size: 13px; }
.badges { position: absolute; left: 12px; top: 12px; display: flex; gap: 6px; }
.badges .pill { background: #fffffff0; border-color: transparent; box-shadow: 0 2px 10px #15151526; backdrop-filter: blur(8px); -webkit-backdrop-filter: blur(8px); }
.flash { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; gap: 10px; background: #ffffffb8; backdrop-filter: blur(4px); color: var(--fg); font-size: 14px; animation: rise .3s var(--ease-out); }
.body { padding: 18px 20px 6px; display: flex; flex-direction: column; gap: 14px; }
.title-row { display: flex; align-items: baseline; gap: 10px; cursor: pointer; min-width: 0; }
.title-row h3 { font-size: 28px; line-height: 1.1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.id { font-size: 12px; }
.stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin: 0; }
.stats div { min-width: 0; }
.stats dt { font-size: 12px; color: var(--fg-muted); }
.stats dd { margin: 2px 0 0; font-size: 14px; color: var(--fg); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.error { display: flex; gap: 8px; align-items: flex-start; padding: 10px 12px; border-radius: var(--r-md); background: var(--danger-soft); color: var(--danger); font-size: 13px; line-height: 1.5; }
.error svg { flex: none; margin-top: 2px; }
.actions { display: flex; align-items: center; gap: 8px; padding: 14px 16px 16px 20px; margin-top: auto; }
.del:hover { color: var(--danger); }
</style>

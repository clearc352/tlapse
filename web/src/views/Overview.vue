<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import { api } from '../lib/api.js'
import { device, refreshDevice } from '../lib/device.js'
import { toastError } from '../lib/store.js'
import { duration, num } from '../lib/format.js'
import ProjectCard from '../components/ProjectCard.vue'
import Icon from '../components/Icon.vue'

const projects = ref(null)
const loading = ref(false)
const err = ref(null)
const bust = ref(Date.now())

async function load(force = true) {
  loading.value = true
  try {
    const [, list] = await Promise.all([refreshDevice(force), api.projects()])
    projects.value = list
    err.value = null
  } catch (e) { err.value = e; toastError(e) } finally { loading.value = false }
}
let timer
function onVis() { if (!document.hidden) load(false) }
onMounted(() => {
  load()
  timer = setInterval(() => { if (!document.hidden) load(false) }, 30000)
  document.addEventListener('visibilitychange', onVis)
})
onBeforeUnmount(() => { clearInterval(timer); document.removeEventListener('visibilitychange', onVis) })

function onRemoved(id) { projects.value = projects.value.filter((p) => p.id !== id) }
function onSnapped() { bust.value = Date.now() }

const d = computed(() => device.data)
const enabled = computed(() => (projects.value || []).filter((p) => p.enabled).length)
const lowDisk = computed(() => d.value && d.value.freeBytes < d.value.minFreeGB * 1024 ** 3)
const diskRatio = computed(() => {
  if (!d.value) return 0
  const min = d.value.minFreeGB * 1024 ** 3
  // 以 4 倍下限为满刻度，直观看出离暂停线有多远
  return Math.min(1, d.value.freeBytes / (min * 4 || 1))
})
const features = computed(() => {
  const f = d.value?.features || {}
  return [
    { k: 'capture', label: '拍照', on: f.capture },
    { k: 'encode', label: '合成', on: f.encode },
    { k: 'upload', label: '上传', on: f.upload },
    { k: 'cleanup', label: '清理', on: f.cleanup },
  ]
})
const greeting = computed(() => {
  const h = new Date().getHours()
  return h < 6 ? '夜深了' : h < 11 ? '早上好' : h < 14 ? '中午好' : h < 18 ? '下午好' : '晚上好'
})
const fmtStart = (s) => { if (!s) return ''; const t = new Date(s); return isNaN(t) ? s : t.toLocaleString('zh-CN', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }) }
</script>

<template>
  <div class="shell page">
    <header class="head rise">
      <div>
        <span class="eyebrow">{{ greeting }} · 总览</span>
        <h1 class="display h-xl title">
          <template v-if="projects === null">正在唤醒 <em>iPhone 6</em>…</template>
          <template v-else-if="!projects.length">还没有 <em class="pink">项目</em></template>
          <template v-else-if="enabled">{{ enabled }} 个画面正在<br class="br" /><em>定时显影</em></template>
          <template v-else>所有项目都在<br class="br" /><em class="pink">暂停</em>中</template>
        </h1>
      </div>
      <button class="btn" :disabled="loading" @click="load(true)"><span v-if="loading" class="spinner"></span><Icon v-else name="refresh" />刷新</button>
    </header>

    <!-- 设备 -->
    <section class="device rise" style="animation-delay: 60ms" aria-label="设备状态">
      <template v-if="d">
        <div class="tile">
          <span class="k"><Icon :name="d.battery?.charging ? 'bolt' : 'battery'" size="14" />电量</span>
          <span class="v display">{{ d.battery?.percent ?? '—' }}<small>%</small></span>
          <span class="s">{{ d.battery?.charging ? '充电中' : '未充电' }}<template v-if="d.battery?.temperatureC != null"> · {{ d.battery.temperatureC.toFixed(1) }}°C</template></span>
          <div class="bar"><i :style="{ width: (d.battery?.percent || 0) + '%' }" :class="{ low: d.battery?.percent <= 20 }"></i></div>
        </div>
        <div class="tile" :class="{ alarm: lowDisk }">
          <span class="k"><Icon name="disk" size="14" />剩余空间</span>
          <span class="v display">{{ d.freeText }}</span>
          <span class="s">低于 {{ d.minFreeGB }} GB 时定时拍摄会暂停</span>
          <div class="bar"><i :style="{ width: diskRatio * 100 + '%' }" :class="{ low: lowDisk }"></i><b :style="{ left: '25%' }" title="暂停线"></b></div>
        </div>
        <div class="tile">
          <span class="k"><Icon name="clock" size="14" />守护进程</span>
          <span class="v display">{{ duration(d.uptimeSeconds) }}</span>
          <span class="s mono">pid {{ d.pid }} · v{{ d.version }}<template v-if="d.startedAt"> · {{ fmtStart(d.startedAt) }} 启动</template></span>
        </div>
        <div class="tile">
          <span class="k"><Icon name="wifi" size="14" />监听</span>
          <template v-if="d.listeners && d.listeners.length">
            <span class="v display">{{ d.listeners.length }}<small> 个地址</small></span>
            <span class="s mono addr">{{ d.listeners.join('  ·  ') }}</span>
          </template>
          <template v-else>
            <span class="v display faint">等待</span>
            <span class="s">还在等局域网，Wi-Fi 连上后会出现地址</span>
          </template>
        </div>
      </template>
      <template v-else>
        <div v-for="i in 4" :key="i" class="tile"><div class="skeleton" style="height: 96px"></div></div>
      </template>
    </section>

    <div v-if="d" class="meta rise" style="animation-delay: 100ms">
      <div class="feats">
        <span v-for="f in features" :key="f.k" class="pill" :class="f.on ? 'live' : 'paused'" :title="f.on ? '当前进程有这项能力' : '当前进程没有这项能力'">
          <span class="dot" v-if="f.on"></span>{{ f.label }}{{ f.on ? '' : ' · 不可用' }}
        </span>
      </div>
      <span class="muted small">{{ num(d.projectCount) }} 个项目 · {{ num(d.enabledCount) }} 个启用 · 存储在 <span class="mono">{{ d.storageRoot }}</span></span>
    </div>

    <hr class="rule" />

    <!-- 项目 -->
    <section class="projects">
      <div class="sec-head">
        <h2 class="display h-lg">项目</h2>
        <router-link to="/new" class="btn sm"><Icon name="plus" size="14" />新建项目</router-link>
      </div>
      <div v-if="projects === null" class="grid">
        <div v-for="i in 2" :key="i" class="skeleton" style="height: 420px; border-radius: 16px"></div>
      </div>
      <div v-else-if="!projects.length" class="empty">
        <p class="display">一个画面也还没有</p>
        <p>新建一个项目，定好间隔和合成方式。新建的项目默认是暂停的，你可以先手动拍几张看构图。</p>
        <router-link to="/new" class="btn foil" style="margin-top: 20px">新建第一个项目</router-link>
      </div>
      <div v-else class="grid">
        <ProjectCard v-for="(p, i) in projects" :key="p.id" :project="p" :bust="bust" class="rise" :style="{ animationDelay: 120 + i * 60 + 'ms' }" @removed="onRemoved" @snapped="onSnapped" />
      </div>
    </section>
  </div>
</template>

<style scoped>
.page { padding-top: clamp(40px, 7vh, 88px); }
.head { display: flex; align-items: flex-end; justify-content: space-between; gap: 24px; margin-bottom: 40px; }
.title { margin-top: 14px; }
.br { display: none; }
@media (max-width: 640px) { .br { display: inline; } }
.device { display: grid; grid-template-columns: repeat(4, 1fr); gap: 1px; background: var(--rule); border: 1px solid var(--border); border-radius: var(--r-lg); overflow: hidden; box-shadow: var(--shadow-1); }
.tile { background: var(--surface); padding: 20px 22px 22px; display: flex; flex-direction: column; gap: 6px; min-width: 0; position: relative; }
.tile .k { display: inline-flex; align-items: center; gap: 6px; font-size: 12.5px; color: var(--fg-muted); }
.tile .v { font-size: 40px; line-height: 1.1; }
.tile .v small { font-size: 18px; color: var(--fg-muted); font-family: var(--font-body); margin-left: 2px; }
.tile .s { font-size: 12.5px; color: var(--fg-muted); }
.tile .addr { word-break: break-all; }
.tile.alarm { background: linear-gradient(180deg, #e44e5a12, var(--surface)); }
.tile.alarm .v { color: var(--danger); }
.bar { position: relative; height: 3px; background: #15151514; border-radius: 3px; margin-top: 8px; }
.bar i { position: absolute; inset: 0 auto 0 0; border-radius: 3px; background: linear-gradient(90deg in oklch, #b76dd7, #3b6ff6); transition: width var(--dur-5) var(--ease-out); }
.bar i.low { background: var(--danger); }
.bar b { position: absolute; top: -3px; width: 1px; height: 9px; background: var(--fg-muted); }
.meta { display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin: 16px 0 48px; }
.feats { display: flex; gap: 6px; flex-wrap: wrap; }
.small { font-size: 13px; }
.projects { margin-top: 48px; }
.sec-head { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 24px; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 380px), 1fr)); gap: 20px; }
@media (max-width: 960px) { .device { grid-template-columns: repeat(2, 1fr); } }
@media (max-width: 520px) { .device { grid-template-columns: 1fr; } .head { flex-direction: column; align-items: flex-start; } }
</style>

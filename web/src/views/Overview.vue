<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import { motion } from 'motion-v'
import { api } from '../lib/api.js'
import { device, refreshDevice } from '../lib/device.js'
import { toastError } from '../lib/store.js'
import ProjectCard from '../components/ProjectCard.vue'
import Icon from '../components/Icon.vue'
const projects = ref(null), loading = ref(false), err = ref(null), bust = ref(Date.now())
const filter = ref('all'), search = ref(''), searching = ref(false)
let active = true, request = 0, timer
async function load(force = true) {
  const key = ++request
  loading.value = true
  try {
    const [, list] = await Promise.all([refreshDevice(force), api.projects()])
    if (!active || key !== request) return
    projects.value = list; err.value = null
    if (force) bust.value = Date.now()
  } catch (e) { if (active && key === request) { err.value = e; toastError(e) } }
  finally { if (active && key === request) loading.value = false }
}
function onVis() { if (!document.hidden) load(false) }
onMounted(() => { load(); timer = setInterval(onVis, 30000); document.addEventListener('visibilitychange', onVis) })
onBeforeUnmount(() => { active = false; request++; clearInterval(timer); document.removeEventListener('visibilitychange', onVis) })
function onRemoved(id) { projects.value = projects.value.filter(p => p.id !== id) }
const shown = computed(() => (projects.value || []).filter(p => (filter.value === 'all' || p.enabled === (filter.value === 'live')) && (p.name || p.id).toLowerCase().includes(search.value.trim().toLowerCase())))
const d = computed(() => device.data)
const lowDisk = computed(() => d.value && d.value.freeBytes < d.value.minFreeGB * 1024 ** 3)
</script>
<template>
  <div class="shell page">
    <header class="head">
      <div class="row gap-12"><h1 class="display h-xl">项目</h1><span v-if="projects" class="total num">{{ projects.length }}</span></div>
      <div class="row gap-8">
        <span v-if="d" class="device muted"><Icon :name="d.battery?.charging ? 'bolt' : 'battery'" />{{ d.battery?.percent ?? '—' }}%<span class="sep">·</span>{{ d.freeText }}</span>
        <button class="btn ghost icon" aria-label="搜索项目" title="搜索项目" :aria-expanded="searching" @click="searching = !searching; search = ''"><Icon name="search" :size="20" /></button>
        <button class="btn ghost icon" :disabled="loading" aria-label="刷新项目" title="刷新" @click="load(true)"><span v-if="loading" class="spinner"></span><Icon v-else name="refresh" :size="19" /></button>
        <router-link to="/new" class="btn solid icon" title="新建项目" aria-label="新建项目"><Icon name="plus" :size="20" /></router-link>
      </div>
    </header>
    <div class="filters">
      <div class="filter-tabs" aria-label="项目状态">
        <button v-for="[value,label] in [['all','全部'],['live','拍摄中'],['paused','已暂停']]" :key="value" :class="{ on: filter === value }" :aria-pressed="filter === value" @click="filter = value">{{ label }}</button>
      </div>
      <input v-if="searching" v-model="search" class="input search" aria-label="搜索项目" placeholder="搜索项目" />
      <span class="grow"></span><span class="muted caption">让时间，慢慢显影。</span>
    </div>
    <p v-if="lowDisk" class="warning" role="status"><Icon name="disk" />空间不足 {{ d.minFreeGB }} GB，定时拍摄可能暂停</p>
    <p v-if="err && projects" class="warning" role="status">刷新失败，已保留上次结果 <button class="btn sm" @click="load(true)">重试</button></p>
    <div v-if="projects === null && !err" class="gallery" aria-label="载入项目"><div v-for="n in 3" :key="n" class="skeleton" style="height: 350px"></div></div>
    <div v-else-if="projects === null" class="empty"><p>无法载入项目</p><button class="btn" @click="load(true)">重试</button></div>
    <div v-else-if="!projects.length" class="empty"><p class="display">从一个画面开始</p><router-link to="/new" class="btn solid" style="margin-top:20px"><Icon name="plus" />新建项目</router-link></div>
    <div v-else-if="!shown.length" class="empty">没有匹配的项目</div>
    <div v-else class="gallery">
      <motion.div v-for="(p,index) in shown" :key="p.id" layout="position" class="gallery-item" :class="{ featured: index % 3 === 0 }" :transition="{ duration: .3 }">
        <ProjectCard :project="p" :bust="bust" :featured="index % 3 === 0" @removed="onRemoved" @snapped="bust = Date.now()" />
      </motion.div>
    </div>
  </div>
</template>
<style scoped>
.page { padding-top: 42px; } .head { display: flex; align-items: center; justify-content: space-between; gap: 20px; margin-bottom: 28px; } .total { align-self: flex-start; color: var(--fg-muted); font-size: 13px; padding-top: 4px; }
.device { display: inline-flex; align-items: center; gap: 6px; margin-right: 16px; font-size: 11px; } .sep { margin: 0 5px; }
.filters { display: flex; align-items: center; gap: 16px; margin-bottom: 32px; min-height: 44px; }
.filter-tabs { display: flex; gap: 23px; } .filter-tabs button { min-height: 44px; padding: 0; border: 0; background: transparent; color: var(--fg-muted); cursor: pointer; position: relative; font-size: 13px; white-space: nowrap; } .filter-tabs button.on { color: var(--fg); font-weight: 700; } .filter-tabs button.on::after { content: ''; position: absolute; bottom: 4px; left: 0; width: 12px; height: 2px; background: var(--fg); }
.search { width: 200px; } .caption { font-size: 11px; letter-spacing: .08em; }
.gallery { display: grid; grid-template-columns: 1fr 1fr; gap: 32px 36px; align-items: stretch; } .gallery-item { min-width: 0; } .gallery-item.featured { grid-row: span 2; }
.warning { display: flex; align-items: center; gap: 10px; color: var(--warn); font-size: 12px; padding: 12px 0 24px; }
@media (max-width: 980px) { .device { display: none; } .gallery { gap: 24px; } }
@media (max-width: 680px) { .page { padding-top: 30px; } .head { margin-bottom: 20px; } .gallery { grid-template-columns: 1fr; gap: 32px; } .gallery-item.featured { grid-row: auto; } .caption { display: none; } .filters { flex-wrap: wrap; gap: 10px; margin-bottom: 24px; } .search { width: 100%; } .head .row { gap: 4px; } }
</style>

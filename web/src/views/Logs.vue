<script setup>
import { ref, computed, onMounted, onBeforeUnmount, nextTick, watch } from 'vue'
import { api } from '../lib/api.js'
import { toastError } from '../lib/store.js'
import Icon from '../components/Icon.vue'

const lines = ref(null)
const tail = ref(Number(localStorage.getItem('tlapse.tail') || 200))
const q = ref('')
const level = ref('all')
const auto = ref(false)
const loading = ref(false)
const box = ref(null)
const stick = ref(true)
const at = ref(null)

async function load() {
  loading.value = true
  try {
    lines.value = await api.logs(tail.value)
    at.value = new Date()
    if (stick.value) { await nextTick(); box.value && (box.value.scrollTop = box.value.scrollHeight) }
  } catch (e) { toastError(e); if (lines.value === null) lines.value = [] } finally { loading.value = false }
}
watch(tail, (v) => { localStorage.setItem('tlapse.tail', String(v)); load() })
let t
watch(auto, (v) => { clearInterval(t); if (v) t = setInterval(() => { if (!document.hidden) load() }, 10000) })
onMounted(load)
onBeforeUnmount(() => clearInterval(t))
function onScroll() { const el = box.value; stick.value = el.scrollHeight - el.scrollTop - el.clientHeight < 40 }

// 解析：2026-11-15 23:03:50 [info] 消息
const RE = /^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) \[(\w+)\] ?(.*)$/
const KEY = [
  [/方向 .*尺寸=|已保存照片|已合成|已上传/, 'good'],
  [/失败|错误|error|无法|拒绝|被杀|killed/i, 'bad'],
  [/没有快门声开关|跳过|太暗|空间不足|已关闭摄像头/, 'note'],
]
const parsed = computed(() => (lines.value || []).map((raw, i) => {
  const m = RE.exec(raw)
  const msg = m ? m[4] : raw
  let tag = ''
  for (const [re, k] of KEY) if (re.test(msg)) { tag = k; break }
  return { i, raw, date: m?.[1] || '', time: m?.[2] || '', lv: (m?.[3] || '').toLowerCase(), msg, tag }
}))
const shown = computed(() => {
  const s = q.value.trim().toLowerCase()
  return parsed.value.filter((l) => {
    if (level.value === 'warn' && !(l.lv === 'warn' || l.lv === 'warning' || l.lv === 'error' || l.tag === 'bad')) return false
    if (level.value === 'snap' && !/拍|快门|摄像头|方向|尺寸/.test(l.msg)) return false
    return !s || l.raw.toLowerCase().includes(s)
  })
})
const QUICK = [['方向', '照片写完'], ['已关闭摄像头', '摄像头关闭'], ['快门声', '快门声'], ['合成', '合成'], ['上传', '上传']]
</script>

<template>
  <div class="shell page">
    <header class="head rise">
      <div>
        <h1 class="display h-xl">日志</h1>
      </div>
    </header>

    <div class="bar">
      <div class="search">
        <Icon name="search" size="16" />
        <input class="input" v-model="q" placeholder="搜索日志" aria-label="搜索日志" spellcheck="false" />
      </div>
      <div class="seg">
        <button :class="{ on: level === 'all' }" @click="level = 'all'">全部</button>
        <button :class="{ on: level === 'snap' }" @click="level = 'snap'">拍照</button>
        <button :class="{ on: level === 'warn' }" @click="level = 'warn'">问题</button>
      </div>
      <select class="select tail" v-model.number="tail" aria-label="行数">
        <option :value="100">100 行</option><option :value="200">200 行</option><option :value="400">400 行</option>
      </select>
      <span class="grow"></span>
      <label class="auto muted"><button class="switch" role="switch" :aria-checked="auto" @click="auto = !auto" aria-label="自动刷新"></button>每 10 秒</label>
      <button class="btn sm" :disabled="loading" @click="load"><span v-if="loading" class="spinner"></span><Icon v-else name="refresh" size="14" />刷新</button>
    </div>
    <div class="quick">
      <button v-for="[k, t] in QUICK" :key="k" class="pill qk" :class="{ on: q === k }" @click="q = q === k ? '' : k">{{ t }}</button>
      <span class="faint at" v-if="at">更新于 {{ at.toLocaleTimeString('zh-CN') }} · 显示 {{ shown.length }} / {{ parsed.length }}</span>
    </div>

    <div class="term panel" ref="box" @scroll="onScroll">
      <div v-if="lines === null" class="skeleton" style="height: 100%"></div>
      <div v-else-if="!shown.length" class="none faint">{{ parsed.length ? '没有匹配的行' : '日志是空的' }}</div>
      <div v-for="l in shown" :key="l.i" class="ln" :class="[l.lv, l.tag]">
        <span class="tm">{{ l.time || '' }}</span>
        <span class="lv">{{ l.lv }}</span>
        <span class="msg">{{ l.msg }}</span>
      </div>
    </div>
    <button v-if="!stick && lines?.length" class="btn sm jump" @click="stick = true; box.scrollTop = box.scrollHeight">↓ 跳到最新</button>
  </div>
</template>

<style scoped>
.page { padding-top: 42px; position: relative; }
.head { margin-bottom: 32px; }
.head h1 { margin: 0; }
.lead { max-width: 46em; font-size: 14.5px; }
.bar { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-bottom: 10px; }
.search { position: relative; width: min(320px, 100%); }
.search svg { position: absolute; left: 12px; top: 50%; transform: translateY(-50%); color: var(--fg-muted); }
.search .input { padding-left: 34px; }
.tail { width: 110px; }
.auto { display: inline-flex; align-items: center; gap: 8px; font-size: 13px; }
.quick { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; margin-bottom: 14px; }
.qk { cursor: pointer; background: transparent; }
.qk.on { color: #fff; background: #151515; border-color: #151515; }
.at { margin-left: auto; font-size: 12px; }
.term { height: min(68vh, 760px); overflow: auto; padding: 14px 0; font-family: var(--font-mono); font-size: 12px; line-height: 1.8; background: var(--surface); }
.none { padding: 40px; text-align: center; font-family: var(--font-body); }
.ln { display: grid; grid-template-columns: 72px 52px 1fr; gap: 12px; padding: 6px 18px; border-left: 2px solid transparent; }
.ln:hover { background: #1515150a; }
.tm { color: var(--fg-faint); }
.lv { color: var(--fg-faint); }
.msg { color: var(--fg-body); white-space: pre-wrap; word-break: break-word; }
.ln.warn .lv, .ln.warning .lv { color: var(--warn); }
.ln.error .lv { color: var(--danger); }
.ln.good { border-left-color: var(--ok); }
.ln.good .msg { color: var(--ok); }
.ln.bad { border-left-color: var(--danger); }
.ln.bad .msg { color: var(--danger); }
.ln.note .msg { justify-self: start; color: var(--fg); background: var(--wash); }
.jump { position: absolute; right: calc(var(--gutter) + 20px); bottom: 20px; }
@media (max-width: 640px) { .ln { grid-template-columns: 60px 1fr; } .lv { display: none; } }
</style>

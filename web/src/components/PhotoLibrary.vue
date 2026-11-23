<script setup>
import { ref, computed, watch, onMounted, onBeforeUnmount, nextTick } from 'vue'
import { api, media } from '../lib/api.js'
import { photoSnapshot, deletePhotos, deletionMessage } from '../lib/photoOperations.js'
import { toast, toastError, confirmDialog } from '../lib/store.js'
import { dateLabel, dateLong, bytes, num } from '../lib/format.js'
import VirtualGrid from './VirtualGrid.vue'
import Lightbox from './Lightbox.vue'
import SafeImg from './SafeImg.vue'
import Icon from './Icon.vue'

const props = defineProps({ projectId: String, refreshKey: Number })
const emit = defineEmits(['changed', 'count'])

const dates = ref(null)
const date = ref('')
const frames = ref([])
const loadingFrames = ref(false)
const ratio = ref(3 / 4)
const density = ref(Number(localStorage.getItem('tlapse.density') || 168))
watch(density, (v) => localStorage.setItem('tlapse.density', String(v)))

const selecting = ref(false)
const selected = ref(new Set())
let lastClicked = -1
const lbIndex = ref(-1)
const deleting = ref(false)
const grid = ref(null)
const strip = ref(null)

let active = true, viewEpoch = 0, datesRequest = 0, framesRequest = 0
const sameView = (ctx) => active && ctx.epoch === viewEpoch && ctx.projectId === props.projectId && ctx.date === date.value
const operation = (names) => ({ ...photoSnapshot(props.projectId, date.value, names), epoch: viewEpoch })

async function loadDates(keep = true) {
  const id = props.projectId, request = ++datesRequest
  try {
    const list = await api.dates(id)
    if (!active || id !== props.projectId || request !== datesRequest) return
    dates.value = list
    emit('count', list.length)
    if (!list.length) { date.value = ''; frames.value = []; return }
    if (!keep || !list.includes(date.value)) date.value = list[0]
    else await loadFrames()
  } catch (e) {
    if (!active || id !== props.projectId || request !== datesRequest) return
    toastError(e); if (dates.value === null) dates.value = []
  }
}
async function loadFrames() {
  const ctx = operation([]), request = ++framesRequest
  if (!ctx.date) { loadingFrames.value = false; return }
  loadingFrames.value = true
  try {
    const list = await api.frames(ctx.projectId, ctx.date)
    if (!sameView(ctx) || request !== framesRequest) return
    frames.value = list.map((f) => ({ ...f, __key: f.name }))
    clearSel()
    lbIndex.value = -1
    detectRatio(ctx)
  } catch (e) { if (sameView(ctx) && request === framesRequest) toastError(e) }
  finally { if (sameView(ctx) && request === framesRequest) loadingFrames.value = false }
}
function detectRatio(ctx) {
  const f = frames.value[0]
  if (!f) return
  const im = new Image()
  im.onload = () => { if (sameView(ctx) && im.naturalWidth && im.naturalHeight) ratio.value = Math.min(1.8, Math.max(.55, im.naturalWidth / im.naturalHeight)) }
  im.src = media.thumb(ctx.projectId, f.kind, ctx.date, f.name)
}
watch(date, () => {
  viewEpoch++; clearSel(); lbIndex.value = -1; frames.value = []
  loadFrames(); nextTick(scrollChipIntoView)
}, { flush: 'sync' })
watch(() => props.projectId, () => {
  viewEpoch++; datesRequest++; framesRequest++; dates.value = null
  date.value = ''; frames.value = []; clearSel(); lbIndex.value = -1
  loadDates(false)
}, { flush: 'sync' })
watch(() => props.refreshKey, () => loadDates(true))
onMounted(() => loadDates(false))
onBeforeUnmount(() => { active = false; datesRequest++; framesRequest++ })

const dayBytes = computed(() => frames.value.reduce((s, f) => s + (f.bytes || 0), 0))
const dateIdx = computed(() => (dates.value || []).indexOf(date.value))
function stepDate(d) { const i = dateIdx.value + d; if (dates.value && i >= 0 && i < dates.value.length) date.value = dates.value[i] }
function scrollChipIntoView() { strip.value?.querySelector('.chip.on')?.scrollIntoView({ inline: 'center', block: 'nearest', behavior: 'smooth' }) }

// —— 选择 ——
function clearSel() { selected.value = new Set(); lastClicked = -1 }
function toggleSelecting() { selecting.value = !selecting.value; if (!selecting.value) clearSel() }
function onCell(e, i) {
  if (!selecting.value && !(e.metaKey || e.ctrlKey || e.shiftKey)) { lbIndex.value = i; return }
  selecting.value = true
  const s = new Set(selected.value)
  const name = frames.value[i].name
  if (e.shiftKey && lastClicked >= 0) {
    const [a, b] = [Math.min(lastClicked, i), Math.max(lastClicked, i)]
    for (let k = a; k <= b; k++) s.add(frames.value[k].name)
  } else s.has(name) ? s.delete(name) : s.add(name)
  lastClicked = i
  selected.value = s
}
const allSelected = computed(() => frames.value.length > 0 && selected.value.size === frames.value.length)
function selectAll() { selected.value = allSelected.value ? new Set() : new Set(frames.value.map((f) => f.name)) }

// —— 下载：每一次链接都使用发起时的快照 ——
const downloading = ref(false)
function downloadOne(ctx, name) {
  const a = document.createElement('a')
  a.href = media.frameDownload(ctx.projectId, ctx.date, name)
  a.download = name
  document.body.appendChild(a); a.click(); a.remove()
}
async function downloadSelected() {
  if (downloading.value) return
  const ctx = operation(selected.value)
  downloading.value = true
  try {
    if (ctx.names.length > 1) toast(`开始下载 ${ctx.names.length} 张原图。浏览器可能会询问是否允许下载多个文件。`, 'info', 6000)
    for (const name of ctx.names) { downloadOne(ctx, name); await new Promise((r) => setTimeout(r, 450)) }
  } finally { downloading.value = false }
}

// —— 删除：确认文案、请求、结果和视图更新共用同一目标 ——
const DEL_NOTE = '原图和缩略图会一起从手机上删掉，无法恢复。\n不会改变累计张数（frameCount），也不会改动已经合成的视频。'
async function runDelete(ctx, single = false) {
  deleting.value = true
  try {
    const result = await deletePhotos(ctx, api.deleteFrame)
    const failed = result.failed.length || result.unattempted.length
    toast(`${ctx.projectId} · ${dateLong(ctx.date)}：${deletionMessage(result)}`, failed ? 'warn' : 'ok', failed ? 9000 : 5000)
    if (active && ctx.projectId === props.projectId && (result.deleted.length || result.missing.length)) emit('changed')
    if (!sameView(ctx)) return
    // 刷新可能改变排序，按文件名移除，绝不复用确认前的数组下标。
    framesRequest++
    loadingFrames.value = false
    const gone = new Set([...result.deleted, ...result.missing])
    const current = frames.value[lbIndex.value]?.name
    frames.value = frames.value.filter((f) => !gone.has(f.name))
    selected.value = new Set([...selected.value].filter((name) => !gone.has(name)))
    if (single && frames.value.length) {
      const index = frames.value.findIndex((f) => f.name === current)
      lbIndex.value = index >= 0 ? index : Math.min(lbIndex.value, frames.value.length - 1)
    } else lbIndex.value = -1
    if (!failed) selecting.value = false
    if (!frames.value.length && !failed) await loadDates(true)
  } finally { deleting.value = false }
}
async function deleteSelected() {
  if (deleting.value) return
  const ctx = operation(selected.value)
  if (!ctx.names.length) return
  deleting.value = true
  const yes = await confirmDialog({ title: `删除 ${ctx.names.length} 张照片？`, body: `${ctx.projectId} · ${dateLong(ctx.date)}\n\n${DEL_NOTE}`, confirmText: `删除 ${ctx.names.length} 张`, tone: 'danger' })
  if (!yes) { deleting.value = false; return }
  await runDelete(ctx)
}
async function deleteFromLightbox(f) {
  if (!f || deleting.value) return
  const ctx = operation([f.name])
  deleting.value = true
  const yes = await confirmDialog({ title: `删除 ${f.label} 这张？`, body: `${ctx.projectId} · ${dateLong(ctx.date)} · ${ctx.names[0]}\n\n${DEL_NOTE}`, confirmText: '删除', tone: 'danger' })
  if (!yes) { deleting.value = false; return }
  await runDelete(ctx, true)
}
watch(lbIndex, (i) => { if (i >= 0) grid.value?.reveal(i) })

defineExpose({ reload: () => loadDates(true) })
</script>

<template>
  <section class="lib">
    <div v-if="dates === null" class="skeleton" style="height: 320px"></div>
    <div v-else-if="!dates.length" class="empty">
      <p class="display">还没有照片</p>
      <p>用左侧的「拍一张」手动拍一张试试构图。照片只存在手机的项目目录里，不会进入 iPhone 的「照片」。</p>
    </div>

    <template v-else>
      <!-- 日期条 -->
      <div class="dates">
        <button class="btn sm icon" :disabled="dateIdx <= 0" @click="stepDate(-1)" title="较新的一天"><Icon name="chevronLeft" size="14" /></button>
        <div class="strip" ref="strip">
          <button v-for="d in dates" :key="d" class="chip" :class="{ on: d === date }" @click="date = d">{{ dateLabel(d) }}</button>
        </div>
        <button class="btn sm icon" :disabled="dateIdx >= dates.length - 1" @click="stepDate(1)" title="更早的一天"><Icon name="chevronRight" size="14" /></button>
      </div>

      <!-- 工具条：吸顶 -->
      <div class="toolbar" :class="{ sel: selecting }">
        <template v-if="!selecting">
          <div class="sum">
            <span class="display d">{{ dateLong(date) }}</span>
            <span class="muted num">{{ num(frames.length) }} 张 · {{ bytes(dayBytes) }}</span>
          </div>
          <span class="grow"></span>
          <label class="dens muted" title="格子大小"><Icon name="grid" size="14" /><input type="range" class="range" min="110" max="300" step="10" v-model.number="density" :style="{ '--fill': ((density - 110) / 190 * 100) + '%' }" /></label>
          <button class="btn sm" @click="loadFrames" :disabled="loadingFrames"><Icon name="refresh" size="14" />刷新</button>
          <button class="btn sm" :disabled="!frames.length" @click="toggleSelecting"><Icon name="select" size="14" />选择</button>
        </template>
        <template v-else>
          <span class="count">已选 <b class="num">{{ selected.size }}</b> 张</span>
          <button class="btn sm ghost" @click="selectAll">{{ allSelected ? '全不选' : '全选当天' }}</button>
          <span class="grow"></span>
          <button class="btn sm" :disabled="!selected.size || downloading" @click="downloadSelected"><Icon name="download" size="14" />下载</button>
          <button class="btn sm danger" :disabled="!selected.size || deleting" @click="deleteSelected"><span v-if="deleting" class="spinner"></span><Icon v-else name="trash" size="14" />删除</button>
          <button class="btn sm solid" @click="toggleSelecting">完成</button>
        </template>
      </div>

      <div v-if="loadingFrames && !frames.length" class="skeleton" style="height: 280px"></div>
      <div v-else-if="!frames.length" class="empty">这一天没有照片了</div>
      <VirtualGrid v-else ref="grid" :items="frames" :ratio="ratio" :min-cell="density" :gap="6">
        <template #default="{ item, index }">
          <button class="tile" :class="{ picked: selected.has(item.name), selecting }" @click="onCell($event, index)" :aria-label="`${item.label}${selecting ? (selected.has(item.name) ? '，已选' : '，未选') : ''}`">
            <SafeImg :src="media.thumb(projectId, item.kind, date, item.name)" :alt="item.label" />
            <span class="t num">{{ item.label }}</span>
            <span class="tick" v-if="selecting"><Icon name="check" size="12" /></span>
          </button>
        </template>
      </VirtualGrid>
      <p v-if="frames.length" class="tip faint">点开看原图。按住 ⌘/Ctrl 点选多张，Shift 连选一段。</p>
    </template>

    <Lightbox v-if="lbIndex >= 0 && frames[lbIndex]" :project-id="projectId" :date="date" :frames="frames" v-model:index="lbIndex" :deleting="deleting" @close="lbIndex = -1" @delete="deleteFromLightbox" />
  </section>
</template>

<style scoped>
.dates { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
.strip { flex: 1; min-width: 0; display: flex; gap: 6px; overflow-x: auto; scrollbar-width: none; padding: 2px 14px; mask-image: linear-gradient(90deg, transparent, #000 16px, #000 calc(100% - 16px), transparent); }
.strip::-webkit-scrollbar { display: none; }
.chip { flex: none; height: 32px; padding: 0 14px; border-radius: var(--r-full); border: 1px solid var(--border); background: transparent; color: var(--fg-muted); font-size: 13px; cursor: pointer; white-space: nowrap; transition: all var(--dur-2); }
.chip:hover { color: var(--fg); border-color: var(--border-strong); background: var(--surface); }
.chip.on { background: #151515; color: #fff; border-color: #151515; }
.toolbar { position: sticky; top: calc(var(--topbar-h) + var(--frame)); z-index: 20; display: flex; align-items: center; gap: 8px; padding: 12px 0; margin-bottom: 8px; background: #ecebe6e6; backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px); border-bottom: 1px solid var(--rule); flex-wrap: wrap; }
.toolbar.sel { border-bottom-color: var(--accent); }
.sum { display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap; }
.sum .d { font-size: 22px; }
.sum .muted { font-size: 13px; }
.dens { display: inline-flex; align-items: center; gap: 8px; margin-right: 6px; }
.dens .range { width: 90px; }
.count { font-size: 14px; color: var(--fg); }
.count b { color: var(--accent-ink); font-weight: 600; }
.tile { position: relative; display: block; width: 100%; height: 100%; padding: 0; border: 0; border-radius: 6px; overflow: hidden; cursor: pointer; background: #dedcd4; outline-offset: 2px; }
.tile :deep(.safe) { transition: transform var(--dur-3) var(--ease-out); }
.tile:hover :deep(img) { filter: brightness(1.08); }
.tile .t { position: absolute; left: 6px; bottom: 6px; padding: 1px 7px; border-radius: 5px; background: #fffffff0; font-size: 11.5px; color: var(--fg); opacity: 0; transition: opacity var(--dur-2); }
.tile:hover .t, .tile.selecting .t { opacity: 1; }
.tick { position: absolute; right: 7px; top: 7px; width: 22px; height: 22px; border-radius: 50%; border: 1.5px solid #fff; background: #15151533; box-shadow: 0 1px 4px #15151540; display: grid; place-items: center; color: transparent; transition: all var(--dur-2); }
.tile.picked :deep(.safe) { transform: scale(.9); border-radius: 6px; }
.tile.picked { box-shadow: inset 0 0 0 2px var(--accent); }
.tile.picked .tick { background: var(--accent); border-color: #fff; color: #fff; }
.tip { font-size: 12px; margin-top: 14px; }
@media (max-width: 640px) { .dens { display: none; } }
</style>

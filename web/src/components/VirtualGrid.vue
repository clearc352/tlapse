<script setup>
// 照片格子的虚拟列表：跟随窗口滚动，只渲染可见行（上下各多渲染几行）。
// 几千张缩略图也只会挂几十个 <img>，不会把手机拖垮。
import { ref, computed, onMounted, onBeforeUnmount, watch, nextTick } from 'vue'

const props = defineProps({
  items: { type: Array, required: true },
  minCell: { type: Number, default: 168 },
  gap: { type: Number, default: 8 },
  ratio: { type: Number, default: 3 / 4 }, // 宽 / 高
  footer: { type: Number, default: 0 },     // 每格下方附加高度
  overscan: { type: Number, default: 3 },
})

const root = ref(null)
const width = ref(0)
const scrollY = ref(0)
const viewH = ref(typeof window !== 'undefined' ? window.innerHeight : 800)
const top = ref(0)

const cols = computed(() => Math.max(2, Math.floor((width.value + props.gap) / (props.minCell + props.gap))))
const cellW = computed(() => (width.value - props.gap * (cols.value - 1)) / cols.value)
const cellH = computed(() => cellW.value / props.ratio + props.footer)
const rowH = computed(() => cellH.value + props.gap)
const rows = computed(() => Math.ceil(props.items.length / cols.value))
const total = computed(() => Math.max(0, rows.value * rowH.value - props.gap))

const range = computed(() => {
  const rel = scrollY.value - top.value
  const first = Math.max(0, Math.floor(rel / rowH.value) - props.overscan)
  const last = Math.min(rows.value - 1, Math.ceil((rel + viewH.value) / rowH.value) + props.overscan)
  return [first, last]
})
const visible = computed(() => {
  const out = []
  if (!width.value) return out
  const [a, b] = range.value
  for (let r = a; r <= b; r++) {
    for (let c = 0; c < cols.value; c++) {
      const i = r * cols.value + c
      if (i >= props.items.length) break
      out.push({ i, item: props.items[i], x: c * (cellW.value + props.gap), y: r * rowH.value })
    }
  }
  return out
})

function measure() {
  if (!root.value) return
  const rect = root.value.getBoundingClientRect()
  width.value = rect.width
  top.value = rect.top + window.scrollY
  viewH.value = window.innerHeight
  scrollY.value = window.scrollY
}
let raf = 0
function onScroll() { if (raf) return; raf = requestAnimationFrame(() => { raf = 0; scrollY.value = window.scrollY; if (root.value) top.value = root.value.getBoundingClientRect().top + window.scrollY }) }
let ro
onMounted(() => {
  measure()
  window.addEventListener('scroll', onScroll, { passive: true })
  window.addEventListener('resize', measure)
  ro = new ResizeObserver(measure); ro.observe(root.value)
})
onBeforeUnmount(() => { window.removeEventListener('scroll', onScroll); window.removeEventListener('resize', measure); ro && ro.disconnect() })
watch(() => props.items, () => nextTick(measure))

/** 让第 i 格出现在视口内（大图翻页后同步滚动） */
function reveal(i) {
  const r = Math.floor(i / cols.value)
  const y = top.value + r * rowH.value
  if (y < window.scrollY + 120 || y + cellH.value > window.scrollY + window.innerHeight) {
    window.scrollTo({ top: y - window.innerHeight / 3, behavior: 'smooth' })
  }
}
defineExpose({ reveal, cols })
</script>

<template>
  <div ref="root" class="vgrid" :style="{ height: total + 'px' }">
    <div v-for="v in visible" :key="v.item.__key ?? v.i" class="cell" :style="{ transform: `translate(${v.x}px, ${v.y}px)`, width: cellW + 'px', height: cellH + 'px' }">
      <slot :item="v.item" :index="v.i" />
    </div>
  </div>
</template>

<style scoped>
.vgrid { position: relative; width: 100%; }
.cell { position: absolute; left: 0; top: 0; }
</style>

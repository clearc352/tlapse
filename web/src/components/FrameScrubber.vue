<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { motion } from 'motion-v'
import type { PanInfo } from 'motion-v'
import { media } from '../lib/api.js'
import { sampleFrames, scrubIndex } from '../lib/framePreview.js'
import SafeImg from './SafeImg.vue'
import Icon from './Icon.vue'
type Frame = { name: string; label: string; kind: string }
const props = defineProps<{ projectId: string; date: string; frames: Frame[] }>()
const emit = defineEmits<{ open: [name: string] }>()
const index = ref(Math.max(0, props.frames.length - 1))
const viewport = ref<HTMLElement>()
const frame = computed(() => props.frames[index.value])
const samples = computed(() => sampleFrames(props.frames.length))
const url = (f: Frame) => media.thumb(props.projectId, f.kind, props.date, f.name)
let origin = 0
watch(() => props.frames, (list, old) => {
  const name = old?.[index.value]?.name
  const next = list.findIndex(f => f.name === name)
  index.value = next >= 0 ? next : Math.max(0, Math.min(index.value, list.length - 1))
})
function onDrag(_: unknown, info: PanInfo) {
  index.value = scrubIndex(origin, info.offset.x, viewport.value?.clientWidth || 1, props.frames.length)
}
</script>
<template>
  <div v-if="frame" class="frame-preview">
    <div class="stage" ref="viewport">
      <motion.div class="stage-drag" drag="x" :drag-constraints="{ left: 0, right: 0 }" :drag-elastic=".06" :drag-momentum="false" :drag-snap-to-origin="true" @drag-start="origin = index" @drag="onDrag" @dblclick="emit('open', frame.name)">
        <SafeImg :src="url(frame)" :alt="frame.label" fit="contain" eager />
      </motion.div>
      <button class="btn icon expand" aria-label="查看原图" title="查看原图" @click="emit('open', frame.name)"><Icon name="expand" :size="19" /></button>
      <span class="stage-time">{{ frame.label }}</span>
    </div>
    <div class="contact-sheet" aria-label="抽样照片">
      <button v-for="i in samples" :key="props.frames[i].name" class="sample" :class="{ on: i === index }" :aria-label="'预览 ' + props.frames[i].label" :aria-pressed="i === index" @click="index = i">
        <SafeImg :src="url(props.frames[i])" :alt="props.frames[i].label" quiet />
      </button>
    </div>
    <div class="timeline">
      <span>{{ props.frames[0]?.label }}</span>
      <input class="frame-range" type="range" min="0" :max="Math.max(0, props.frames.length - 1)" step="1" v-model.number="index" :disabled="props.frames.length < 2" aria-label="照片时间轴" :aria-valuetext="frame.label + '，' + (index + 1) + ' / ' + props.frames.length" />
      <span>{{ props.frames[props.frames.length - 1]?.label }}</span>
    </div>
    <p class="position num">{{ index + 1 }}<span>/ {{ props.frames.length }}</span></p>
  </div>
</template>
<style scoped>
.stage { position: relative; height: clamp(280px,52vh,620px); background: var(--wash); border-radius: 10px; overflow: hidden; }
.stage-drag { width: 100%; height: 100%; cursor: ew-resize; touch-action: pan-y; }
.stage-drag :deep(.safe) { background: transparent; }
.expand { position: absolute; right: 16px; top: 16px; background: #fafaf7e8; border: 0; }
.stage-time { position: absolute; left: 18px; bottom: 15px; padding: 3px 8px; background: #fafaf7e8; border-radius: 5px; color: var(--fg); font-size: 10px; pointer-events: none; }
.contact-sheet { display: grid; grid-auto-columns: minmax(0,1fr); grid-auto-flow: column; gap: 6px; margin: 22px auto 0; max-width: 920px; }
.sample { display: block; height: 68px; border: 0; border-radius: 4px; padding: 0; overflow: hidden; background: var(--wash); cursor: pointer; opacity: .68; transition: opacity .18s; }
.sample:hover,.sample.on { opacity: 1; } .sample.on { outline: 2px solid var(--fg); outline-offset: 3px; }
.timeline { display: flex; align-items: center; gap: 16px; max-width: 920px; margin: 6px auto 0; }
.timeline span { font-size: 10px; color: var(--fg-muted); flex-shrink: 0; }
.frame-range { min-width: 0; flex: 1; accent-color: var(--fg); height: 44px; cursor: ew-resize; }
.position { text-align: center; color: var(--fg); font-size: 11px; } .position span { color: var(--fg-muted); margin-left: 8px; }
@media (max-width: 680px) { .stage { height: min(51vh,440px); min-height: 260px; } .contact-sheet { gap: 4px; margin-top: 18px; } .sample { height: 48px; } .timeline { gap: 10px; } .timeline span { font-size: 9px; } }
</style>

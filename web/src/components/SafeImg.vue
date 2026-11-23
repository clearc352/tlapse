<script setup>
// 图片加载失败时给「重新载入」，不留破图；quiet 时（最新图不存在）安静地空着
import { ref, watch } from 'vue'
const props = defineProps({ src: String, alt: { type: String, default: '' }, quiet: Boolean, fit: { type: String, default: 'cover' }, eager: Boolean })
const state = ref('loading')
const nonce = ref(0)
const url = ref(props.src)
watch(() => props.src, (s) => { url.value = s; state.value = 'loading' })
function retry() {
  nonce.value++
  const sep = props.src.includes('?') ? '&' : '?'
  url.value = `${props.src}${sep}r=${nonce.value}`
  state.value = 'loading'
}
</script>
<template>
  <div class="safe" :class="state">
    <img v-if="url" v-show="state !== 'error'" :src="url" :alt="alt" :loading="eager ? 'eager' : 'lazy'" decoding="async" :style="{ objectFit: fit }" @load="state = 'ok'" @error="state = 'error'" draggable="false" />
    <div v-if="state === 'loading'" class="skel skeleton"></div>
    <div v-if="state === 'error'" class="fail">
      <slot name="empty" v-if="quiet" />
      <button v-else class="btn sm" @click.stop="retry">重新载入</button>
    </div>
  </div>
</template>
<style scoped>
.safe { position: relative; width: 100%; height: 100%; overflow: hidden; background: #dedcd4; }
.safe img { width: 100%; height: 100%; opacity: 0; transition: opacity var(--dur-4) var(--ease-out); }
.safe.ok img { opacity: 1; }
.skel { position: absolute; inset: 0; border-radius: 0; }
.fail { position: absolute; inset: 0; display: grid; place-items: center; color: var(--fg-faint); background: repeating-linear-gradient(135deg, #1515150a 0 10px, transparent 10px 20px), #e4e2da; }
</style>

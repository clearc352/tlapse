<script setup>
import { watch, nextTick, ref } from 'vue'
import { dialog, closeDialog } from '../lib/store.js'
const okBtn = ref(null)
watch(() => dialog.open, async (o) => { if (o) { await nextTick(); okBtn.value?.focus() } })
function onKey(e) { if (e.key === 'Escape') closeDialog(false) }
</script>
<template>
  <transition name="fade">
    <div v-if="dialog.open" class="scrim" @click.self="closeDialog(false)" @keydown="onKey">
      <div class="dlg panel" role="alertdialog" aria-modal="true" :aria-label="dialog.title">
        <h3 class="display h-md">{{ dialog.title }}</h3>
        <p v-if="dialog.body" class="body">{{ dialog.body }}</p>
        <div class="actions">
          <button class="btn" @click="closeDialog(false)">取消</button>
          <button ref="okBtn" class="btn solid" :class="{ danger: dialog.tone === 'danger' }" @click="closeDialog(true)">{{ dialog.confirmText }}</button>
        </div>
      </div>
    </div>
  </transition>
</template>
<style scoped>
.scrim { position: fixed; inset: 0; z-index: 980; background: #ecebe6b3; backdrop-filter: blur(8px) saturate(1.2); display: grid; place-items: center; padding: 16px; }
.dlg { width: min(460px, 100%); padding: 28px; background: var(--surface); box-shadow: 0 40px 80px -24px #15151540; }
.body { margin-top: 12px; color: var(--fg-body); white-space: pre-line; font-size: 14.5px; }
.actions { display: flex; justify-content: flex-end; gap: 10px; margin-top: 24px; }
.fade-enter-active, .fade-leave-active { transition: opacity var(--dur-3) var(--ease-out); }
.fade-enter-from, .fade-leave-to { opacity: 0; }
</style>

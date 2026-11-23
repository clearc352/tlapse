<script setup>
import { toasts, dismissToast } from '../lib/store.js'
</script>
<template>
  <div class="toasts" aria-live="polite">
    <transition-group name="toast">
      <div v-for="t in toasts.list" :key="t.id" class="toast" :class="t.tone" @click="dismissToast(t.id)">{{ t.message }}</div>
    </transition-group>
  </div>
</template>
<style scoped>
.toasts { position: fixed; z-index: 970; left: 50%; bottom: 24px; transform: translateX(-50%); display: flex; flex-direction: column; gap: 8px; align-items: center; width: min(560px, calc(100vw - 32px)); pointer-events: none; }
.toast { pointer-events: auto; cursor: pointer; padding: 11px 18px; border-radius: 14px; background: #151515; border: 0; color: #fffd; font-size: 14px; box-shadow: var(--shadow-2); max-width: 100%; }
.toast.ok { }
.toast.ok::before { content: "● "; color: #6fe0a3; }
.toast.warn { }
.toast.warn::before { content: "● "; color: #ffd36a; }
.toast.danger { }
.toast.danger::before { content: "● "; color: #ff8f8a; }
.toast-enter-active, .toast-leave-active { transition: all var(--dur-4) var(--ease-out); }
.toast-enter-from { opacity: 0; transform: translateY(12px) scale(.98); }
.toast-leave-to { opacity: 0; }
</style>

<script setup>
import { computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { conn, session } from './lib/store.js'
import { api } from './lib/api.js'
import TopBar from './components/TopBar.vue'
import Toasts from './components/Toasts.vue'
import ConfirmDialog from './components/ConfirmDialog.vue'

const route = useRoute()
const router = useRouter()
const bare = computed(() => route.meta.bare)

async function logout() {
  try { await api.logout() } catch {}
  session.loggedIn = false
  router.replace({ name: 'login' })
}
</script>

<template>
  <div class="aurora" aria-hidden="true"></div>
  <TopBar v-if="!bare" @logout="logout" />
  <transition name="drop">
    <div v-if="!conn.online && !bare" class="offline" role="status">
      <span class="dot"></span>
      与手机的连接中断。页面保持原样，照片可能还在手机上保存；网络恢复后操作会继续生效。
    </div>
  </transition>
  <main class="main" :class="{ bare }">
    <router-view v-slot="{ Component, route: r }">
      <transition name="page" mode="out-in">
        <component :is="Component" :key="r.name + (r.params.id || '')" />
      </transition>
    </router-view>
  </main>
  <footer v-if="!bare" class="foot shell">
    <span class="eyebrow">仅限本地网络</span>
    <span class="muted">连接没有加密。只在自己的 Wi-Fi、个人热点或 Tailscale 里打开，不要把 8080 端口转发到公网。</span>
  </footer>
  <Toasts />
  <ConfirmDialog />
</template>

<style>
.aurora {
  position: fixed; inset: 0 0 auto 0; height: 520px; pointer-events: none; z-index: 0;
  background:
    radial-gradient(28% 70% at 12% 0%, #ffe08f55, transparent 70%),
    radial-gradient(30% 60% at 40% 0%, #ffb80022, transparent 70%),
    radial-gradient(34% 70% at 70% 0%, #cd24c01c, transparent 70%),
    radial-gradient(40% 80% at 95% 0%, #009cff22, transparent 70%);
}
.main { position: relative; z-index: 1; min-height: calc(100dvh - var(--topbar-h) - 120px); padding-bottom: 72px; }
.main.bare { min-height: 100dvh; padding: 0; }
.foot { position: relative; z-index: 1; display: flex; gap: 16px; align-items: baseline; flex-wrap: wrap; padding-top: 24px; padding-bottom: 40px; border-top: 1px solid var(--rule); font-size: 13px; }
.offline {
  position: sticky; top: calc(var(--topbar-h) + var(--frame)); z-index: 40; display: flex; align-items: center; justify-content: center; gap: 10px;
  padding: 10px var(--gutter); font-size: 13.5px; color: #151515; background: var(--warn-bg);
}
.offline .dot { width: 8px; height: 8px; border-radius: 50%; background: #151515; animation: blink 1.2s steps(2) infinite; }
@keyframes blink { 50% { opacity: .2; } }
.page-enter-active, .page-leave-active { transition: opacity var(--dur-3) var(--ease-out), transform var(--dur-3) var(--ease-out); }
.page-enter-from { opacity: 0; transform: translateY(8px); }
.page-leave-to { opacity: 0; }
.drop-enter-active, .drop-leave-active { transition: transform var(--dur-3) var(--ease-out), opacity var(--dur-3); }
.drop-enter-from, .drop-leave-to { transform: translateY(-100%); opacity: 0; }
</style>

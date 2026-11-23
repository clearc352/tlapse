<script setup>
import { computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { motion, MotionConfig } from 'motion-v'
import { conn, session } from './lib/store.js'
import { api } from './lib/api.js'
import TopBar from './components/TopBar.vue'
import Toasts from './components/Toasts.vue'
import ConfirmDialog from './components/ConfirmDialog.vue'
const route = useRoute(), router = useRouter()
const bare = computed(() => route.meta.bare)
function focusMain() { document.getElementById('main-content')?.focus() }
async function logout() { try { await api.logout() } catch {} session.loggedIn = false; router.replace({ name: 'login' }) }
</script>
<template>
  <MotionConfig reduced-motion="user">
    <a v-if="!bare" class="skip" href="#main-content" @click.prevent="focusMain">跳到内容</a>
    <TopBar v-if="!bare" @logout="logout" />
    <div v-if="!conn.online && !bare" class="offline" role="status">连接中断，页面已保留。请确认手机网络后重试。</div>
    <main id="main-content" tabindex="-1" class="main" :class="{ bare }">
      <router-view v-slot="{ Component, route: r }"><motion.div :key="r.name + (r.params.id || '')" :initial="{ opacity: 0, y: 8 }" :animate="{ opacity: 1, y: 0 }" :transition="{ duration: .28 }"><component :is="Component" /></motion.div></router-view>
    </main>
    <footer v-if="!bare" class="foot shell"><details><summary>局域网连接</summary><p>连接未加密。仅在可信 Wi-Fi、个人热点或受控 VPN 内使用，不要转发端口到公网。</p></details><span class="grow"></span><a href="./THIRD-PARTY-LICENSES.txt" target="_blank" rel="noopener">MiSans · 许可</a></footer>
    <Toasts /><ConfirmDialog />
  </MotionConfig>
</template>
<style scoped>
.main { margin-left: var(--rail); min-height: calc(100dvh - 72px); padding-bottom: 40px; } .main.bare { margin: 0; min-height: 100dvh; padding: 0; } .main:focus { outline: none; }
.foot { margin-left: var(--rail); display: flex; align-items: flex-start; gap: 24px; padding-top: 16px; padding-bottom: 28px; font-size: 10px; color: var(--fg-muted); }
.foot details { max-width: 440px; } summary { cursor: pointer; } .foot p { margin-top: 8px; } .foot a:hover { color: var(--fg); }
.offline { position: sticky; top: 0; z-index: 70; margin-left: var(--rail); padding: 12px 24px; background: var(--warn-bg); color: var(--warn); text-align: center; font-size: 12px; }
.skip { position: fixed; top: -100px; left: 100px; z-index: 1000; padding: 12px 20px; color: #fff; background: var(--fg); border-radius: 8px; } .skip:focus { top: 12px; }
@media (max-width: 680px) { .main { margin-left: 0; padding-bottom: 80px; } .foot { margin-left: 0; padding-bottom: calc(92px + env(safe-area-inset-bottom)); } .offline { margin-left: 0; } }
</style>

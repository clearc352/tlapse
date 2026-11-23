<script setup>
import { onMounted, onBeforeUnmount, computed, ref } from 'vue'
import { useRoute } from 'vue-router'
import { device, refreshDevice } from '../lib/device.js'
import { conn } from '../lib/store.js'
import Logo from './Logo.vue'
import Icon from './Icon.vue'
const emit = defineEmits(['logout'])
const route = useRoute()
const expanded = ref(false)
let timer
onMounted(() => { refreshDevice().catch(() => {}); timer = setInterval(() => { if (!document.hidden) refreshDevice().catch(() => {}) }, 60000) })
onBeforeUnmount(() => clearInterval(timer))
const d = computed(() => device.data)
</script>
<template>
  <header class="rail">
    <router-link to="/" class="brand" aria-label="tlapse 项目" title="tlapse · 帧轨"><Logo :size="31" /></router-link>
    <nav aria-label="主导航">
      <router-link to="/" class="nav-a" :class="{ on: route.name !== 'logs' }" :aria-current="route.name !== 'logs' ? 'page' : undefined" title="项目" aria-label="项目"><Icon name="layers" :size="21" /></router-link>
      <router-link to="/logs" class="nav-a" active-class="on" title="日志" aria-label="日志"><Icon name="terminal" :size="21" /></router-link>
    </nav>
    <div class="rail-bottom">
      <button class="nav-a" :class="{ on: expanded }" aria-label="设备状态" title="设备状态" :aria-expanded="expanded" @click="expanded = !expanded"><Icon name="phone" :size="21" /><span class="status-dot" :class="{ down: !conn.online }"></span></button>
      <button class="nav-a" title="退出登录" aria-label="退出登录" @click="emit('logout')"><Icon name="logout" :size="20" /></button>
    </div>
  </header>
  <template v-if="expanded">
    <div class="device-dismiss" @click="expanded = false"></div>
    <section class="device-popover panel" aria-label="设备状态">
      <div class="row gap-12"><h2 class="display">iPhone 6</h2><span class="grow"></span><button class="btn ghost icon" aria-label="关闭设备状态" @click="expanded = false"><Icon name="close" /></button></div>
      <dl v-if="d"><div><dt>连接</dt><dd>{{ conn.online ? '已连接' : '中断' }}</dd></div><div><dt>电量</dt><dd>{{ d.battery?.percent ?? '—' }}% {{ d.battery?.charging ? '· 充电中' : '' }}<template v-if="d.battery?.temperatureC != null"> · {{ d.battery.temperatureC.toFixed(1) }}°C</template></dd></div><div><dt>可用空间</dt><dd>{{ d.freeText }} · 下限 {{ d.minFreeGB }} GB</dd></div><div><dt>运行</dt><dd>{{ Math.floor((d.uptimeSeconds || 0) / 3600) }} h</dd></div><div><dt>版本</dt><dd>v{{ d.version }} · pid {{ d.pid }}</dd></div><div><dt>地址</dt><dd>{{ d.listeners?.join(' / ') || '等待网络' }}</dd></div><div><dt>存储</dt><dd>{{ d.storageRoot }}</dd></div><div><dt>能力</dt><dd>{{ Object.entries(d.features || {}).map(([k,v]) => ({capture:'拍照',encode:'合成',upload:'上传',cleanup:'清理'}[k] || k) + (v ? ' ✓' : ' 不可用')).join(' · ') }}</dd></div></dl>
      <p v-else class="muted">{{ device.error ? '无法读取设备状态' : '连接中…' }}</p>
      <button class="btn" :disabled="device.loading" @click="refreshDevice(true).catch(() => {})"><Icon name="refresh" />刷新</button>
    </section>
  </template>
</template>
<style scoped>
.rail { position: fixed; inset: 0 auto 0 0; z-index: 80; width: var(--rail); display: flex; align-items: center; flex-direction: column; border-right: 1px solid var(--rule); background: var(--bg); padding: 24px 12px; }
.brand { display: grid; place-items: center; width: 48px; height: 48px; color: var(--fg); }
nav { display: flex; flex-direction: column; gap: 14px; margin-top: 40px; }
.nav-a { position: relative; width: 44px; height: 44px; display: grid; place-items: center; border: 0; border-radius: 13px; color: var(--fg-muted); background: transparent; cursor: pointer; transition: background .18s,color .18s; }
.nav-a:hover { background: var(--wash); color: var(--fg); } .nav-a.on { background: var(--fg); color: var(--bg); }
.rail-bottom { display: flex; flex-direction: column; gap: 16px; margin-top: auto; }
.status-dot { position: absolute; right: 7px; top: 7px; width: 6px; height: 6px; border-radius: 50%; background: var(--ok); border: 1px solid var(--bg); } .status-dot.down { background: var(--warn); }
.device-dismiss { position: fixed; inset: 0; z-index: 84; }
.device-popover { position: fixed; bottom: 28px; left: calc(var(--rail) + 16px); width: min(390px,calc(100vw - var(--rail) - 36px)); z-index: 85; padding: 22px; box-shadow: 0 12px 50px #24282015; }
.device-popover h2 { font-size: 22px; } dl { margin: 12px 0 22px; font-size: 12px; } dl div { display: flex; gap: 16px; padding: 9px 0; border-bottom: 1px solid var(--rule); } dt { flex-shrink: 0; color: var(--fg-muted); } dd { margin: 0 0 0 auto; text-align: right; overflow-wrap: anywhere; }
@media (max-width: 680px) { .rail { inset: auto 0 0; width: 100%; height: calc(68px + env(safe-area-inset-bottom)); padding: 8px 22px calc(8px + env(safe-area-inset-bottom)); flex-direction: row; border-right: 0; border-top: 1px solid var(--rule); justify-content: space-between; } .brand { display: none; } nav,.rail-bottom { flex-direction: row; margin: 0; gap: 22px; } .device-popover { left: 16px; bottom: calc(84px + env(safe-area-inset-bottom)); width: calc(100vw - 32px); } }
</style>

<script setup>
import { onMounted, onBeforeUnmount, computed } from 'vue'
import { device, refreshDevice } from '../lib/device.js'
import { conn } from '../lib/store.js'
import Icon from './Icon.vue'

const emit = defineEmits(['logout'])
let t
onMounted(() => { refreshDevice().catch(() => {}); t = setInterval(() => refreshDevice().catch(() => {}), 60000) })
onBeforeUnmount(() => clearInterval(t))

const bat = computed(() => device.data?.battery)
const lowDisk = computed(() => {
  const d = device.data
  return d && d.freeBytes != null && d.minFreeGB != null && d.freeBytes < d.minFreeGB * 1024 ** 3
})
</script>

<template>
  <header class="topbar">
    <div class="shell inner">
      <router-link to="/" class="brand" aria-label="tlapse 总览">
        <span class="mark" aria-hidden="true"><i></i><i></i><i></i></span>
        <span class="word display">tlapse</span>
        <span class="ver mono faint" v-if="device.data?.version">v{{ device.data.version }}</span>
      </router-link>

      <nav class="nav" aria-label="主导航">
        <router-link to="/" class="nav-a" exact-active-class="on"><Icon name="grid" />总览</router-link>
        <router-link to="/logs" class="nav-a" active-class="on"><Icon name="terminal" />日志</router-link>
      </nav>

      <div class="right">
        <div class="chips" v-if="device.data">
          <span class="chip" :class="{ warn: bat && bat.percent <= 20 && !bat.charging }" v-if="bat" :title="bat.charging ? '充电中' : '未充电'">
            <Icon :name="bat.charging ? 'bolt' : 'battery'" size="14" />{{ bat.percent }}%
          </span>
          <span class="chip" :class="{ warn: lowDisk }" :title="lowDisk ? '剩余空间低于下限，定时拍摄会暂停' : '剩余空间'">
            <Icon name="disk" size="14" />{{ device.data.freeText }}
          </span>
        </div>
        <span class="conn" :class="conn.online ? 'ok' : 'down'" :title="conn.online ? '已连接手机' : '连接中断'"></span>
        <router-link to="/new" class="btn sm new"><Icon name="plus" size="14" />新建项目</router-link>
        <button class="btn sm ghost icon" title="退出登录" @click="emit('logout')"><Icon name="logout" size="16" /></button>
      </div>
    </div>
  </header>
</template>

<style scoped>
.topbar { position: sticky; top: var(--frame); z-index: 50; height: var(--topbar-h); backdrop-filter: blur(16px) saturate(140%); -webkit-backdrop-filter: blur(16px) saturate(140%); background: #ecebe6d9; border-bottom: 1px solid var(--rule); }
.inner { height: 100%; display: flex; align-items: center; gap: 28px; }
.brand { display: flex; align-items: baseline; gap: 10px; }
.mark { display: grid; grid-template-columns: 6px 6px; grid-template-rows: 6px 6px 6px; gap: 2px; align-self: center; }
.mark i { width: 6px; height: 6px; border-radius: 1.6px; background: var(--accent); }
.mark i:nth-child(1) { grid-area: 1 / 1; }
.mark i:nth-child(2) { grid-area: 2 / 2; background: var(--blue); }
.mark i:nth-child(3) { grid-area: 3 / 1; background: #e8b84a; }
.word { font-size: 26px; line-height: 1; }
.ver { font-size: 11px; }
.nav { display: flex; gap: 4px; }
.nav-a { display: inline-flex; align-items: center; gap: 7px; height: 34px; padding: 0 12px; border-radius: var(--r-full); color: var(--fg-muted); font-size: 14px; transition: color var(--dur-2), background var(--dur-2); }
.nav-a:hover { color: var(--fg); }
.nav-a.on { color: var(--fg); background: var(--surface); box-shadow: 0 1px 3px #1515151f; }
.right { margin-left: auto; display: flex; align-items: center; gap: 10px; }
.chips { display: flex; gap: 6px; }
.chip { display: inline-flex; align-items: center; gap: 5px; font-size: 12.5px; color: var(--fg-muted); padding: 0 8px; height: 26px; border-radius: var(--r-full); border: 1px solid var(--border); }
.chip.warn { color: var(--warn); border-color: #9a6a0040; background: #ffe27a40; }
.conn { width: 8px; height: 8px; border-radius: 50%; }
.conn.ok { background: #2ea86d; box-shadow: 0 0 0 3px #2ea86d26; }
.conn.down { background: #e0a100; box-shadow: 0 0 0 3px #e0a10026; }
@media (max-width: 720px) {
  .chips, .ver { display: none; }
  .inner { gap: 12px; }
  .nav-a { padding: 0 10px; }
  .new { padding: 0 10px; }
}
@media (max-width: 460px) { .nav-a svg { display: none; } .word { font-size: 22px; } }
</style>

<script setup>
import { ref } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { api } from '../lib/api.js'
import { session } from '../lib/store.js'

const router = useRouter()
const route = useRoute()
const token = ref('')
const show = ref(false)
const err = ref('')
const errKind = ref('')
const loading = ref(false)

async function submit() {
  if (!token.value || loading.value) return
  loading.value = true; err.value = ''; errKind.value = ''
  try {
    await api.login(token.value)
    token.value = ''
    session.loggedIn = true
    const next = typeof route.query.next === 'string' && route.query.next.startsWith('/') && !route.query.next.startsWith('/login') ? route.query.next : '/'
    router.replace(next)
  } catch (e) {
    errKind.value = e.kind
    if (e.kind === 'auth') err.value = '口令不对。连续 8 次错误会锁定 5 分钟。'
    else if (e.kind === 'rate') err.value = '尝试次数过多，这个地址被锁定 5 分钟，请稍后再试。'
    else if (e.kind === 'network' || e.kind === 'timeout') err.value = '连不上手机。确认电脑和 iPhone 在同一个 Wi-Fi，守护进程 tlapsed 正在运行。'
    else err.value = e.message
  } finally { loading.value = false }
}
</script>

<template>
  <div class="login">
    <section class="hero">
      <div class="brand">
        <span class="mark"><i></i><i></i><i></i></span>
        <span class="display">tlapse</span>
      </div>
      <h1 class="display h-xl">让时间<br /><em>慢慢</em>显影。</h1>
      <p class="lead">一部 iPhone 6，一条串行快门队列，日复一日把同一个画面存下来。这里是它的控制台和照片库。</p>
      <div class="film" aria-hidden="true">
        <span v-for="i in 9" :key="i" :style="{ '--i': i }"></span>
      </div>
    </section>

    <section class="card panel">
      <span class="eyebrow">控制台登录</span>
      <h2 class="display h-md">输入口令</h2>
      <p class="muted small">口令是手机上 <span class="mono">config.json</span> 里的 <span class="mono">server.token</span>。浏览器不会记住它，登录状态保存在 12 小时有效的会话 Cookie 里。</p>
      <form @submit.prevent="submit" class="stack gap-12">
        <div class="field">
          <label for="tk">口令</label>
          <div class="pw">
            <input id="tk" class="input" :class="{ bad: errKind === 'auth' }" :type="show ? 'text' : 'password'" v-model="token" autocomplete="current-password" autofocus spellcheck="false" />
            <button type="button" class="btn sm ghost eye" @click="show = !show">{{ show ? '隐藏' : '显示' }}</button>
          </div>
          <p v-if="err" class="err" :class="{ net: errKind === 'network' || errKind === 'timeout' }">{{ err }}</p>
        </div>
        <button class="btn lg foil" :disabled="!token || loading">
          <span v-if="loading" class="spinner"></span>{{ loading ? '正在连接手机…' : '进入控制台' }}
        </button>
      </form>
      <div class="note">
        <span class="eyebrow">注意</span>
        <p>连接没有加密（只有 HTTP）。只在自己的 Wi-Fi、个人热点或 Tailscale 里打开，不要把端口转发到公网。</p>
      </div>
    </section>
  </div>
</template>

<style scoped>
.login { min-height: 100dvh; display: grid; grid-template-columns: 1.15fr 1fr; gap: clamp(32px, 6vw, 96px); align-items: center; max-width: 1180px; margin: 0 auto; padding: clamp(32px, 6vw, 80px) var(--gutter); }
.brand { display: flex; align-items: center; gap: 10px; margin-bottom: clamp(40px, 8vh, 96px); }
.brand .display { font-size: 28px; }
.mark { display: grid; grid-template-columns: 6px 6px; grid-template-rows: 6px 6px 6px; gap: 2px; }
.mark i { width: 6px; height: 6px; border-radius: 1.6px; background: var(--accent); }
.mark i:nth-child(1) { grid-area: 1 / 1; } .mark i:nth-child(2) { grid-area: 2 / 2; background: var(--blue); } .mark i:nth-child(3) { grid-area: 3 / 1; background: #e8b84a; }
.hero h1 { margin-bottom: 24px; }
.lead { font-size: 17px; line-height: 1.75; color: var(--fg-body); max-width: 30em; }
.film { display: flex; gap: 6px; margin-top: 48px; }
.film span { width: 44px; height: 58px; border-radius: 6px; border: 1px solid var(--border); background: linear-gradient(180deg, hsl(calc(205 - var(--i) * 18) 70% calc(92% - var(--i) * 3%)), hsl(calc(40 + var(--i) * 12) 85% calc(86% - var(--i) * 2%))); box-shadow: 0 6px 16px -10px #15151566; opacity: 0; animation: frame .7s var(--ease-out) forwards; animation-delay: calc(var(--i) * 90ms); }
@keyframes frame { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; } }
.card { padding: clamp(24px, 3vw, 40px); display: flex; flex-direction: column; gap: 18px; background: var(--surface); }
.small { font-size: 13.5px; line-height: 1.7; }
.pw { position: relative; }
.pw .input { height: 48px; padding-right: 72px; font-size: 16px; letter-spacing: .04em; }
.eye { position: absolute; right: 6px; top: 8px; }
.err { color: var(--danger); font-size: 13px; }
.err.net { color: var(--warn); }
.note { padding-top: 16px; border-top: 1px solid var(--rule); display: flex; flex-direction: column; gap: 6px; font-size: 13px; color: var(--fg-muted); }
@media (max-width: 860px) { .login { grid-template-columns: 1fr; } .brand { margin-bottom: 32px; } .film { display: none; } }
</style>

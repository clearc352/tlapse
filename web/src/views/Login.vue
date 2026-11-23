<script setup>
import { ref } from 'vue'
import { useRouter,useRoute } from 'vue-router'
import { api } from '../lib/api.js'
import { session } from '../lib/store.js'
import Logo from '../components/Logo.vue'
import Icon from '../components/Icon.vue'
const router = useRouter(), route = useRoute()
const token = ref(''), show = ref(false), err = ref(''), errKind = ref(''), loading = ref(false)
async function submit() {
  if (!token.value || loading.value) return
  loading.value = true; err.value = ''; errKind.value = ''
  try {
    await api.login(token.value)
    token.value = ''; session.loggedIn = true
    const target = route.query.next
    const next = typeof target === 'string' && target.startsWith('/') && !target.startsWith('//') && !target.startsWith('/login') ? target : '/'
    router.replace(next)
  } catch (e) {
    errKind.value = e.kind
    if (e.kind === 'auth') err.value = '口令不对，连续 8 次错误会锁定 5 分钟'
    else if (e.kind === 'rate') err.value = '尝试过多，请 5 分钟后再试'
    else if (e.kind === 'network' || e.kind === 'timeout') err.value = '连不上手机，请检查 Wi-Fi 与 tlapsed'
    else err.value = e.message
  } finally { loading.value = false }
}
</script>
<template>
  <div class="login">
    <section class="login-content">
      <div class="wordmark"><Logo :size="44" /><h1 class="display">tlapse</h1></div>
      <p class="tagline">让时间，慢慢显影。</p>
      <form @submit.prevent="submit">
        <div class="password-line">
          <Icon name="lock" :size="17" /><label class="sr-only" for="tk">口令</label>
          <input id="tk" :type="show ? 'text' : 'password'" v-model="token" placeholder="输入口令" autocomplete="current-password" autofocus spellcheck="false" :aria-invalid="!!err" :aria-describedby="err ? 'login-error' : undefined" />
          <button type="button" class="btn ghost icon" @click="show = !show" :aria-label="show ? '隐藏口令' : '显示口令'" :aria-pressed="show"><Icon name="eye" :size="17" /></button>
          <button class="btn solid icon enter" :disabled="!token || loading" aria-label="进入控制台" title="进入"><span v-if="loading" class="spinner"></span><Icon v-else name="arrowRight" :size="20" /></button>
        </div>
        <p v-if="err" id="login-error" class="error" role="alert">{{ err }}</p>
      </form>
      <p class="phone"><Icon name="phone" :size="14" />iPhone 6 <span>·</span> 局域网连接</p>
      <details class="help"><summary>连接帮助</summary><p>口令为 config.json 中的 server.token。仅在可信 Wi-Fi、热点或受控 VPN 内使用，连接未加密，不要转发端口到公网。</p></details>
    </section>
    <a class="license" href="./MiSans-License.pdf" target="_blank" rel="noopener">MiSans</a>
  </div>
</template>
<style scoped>
.login { min-height: 100dvh; display: grid; place-items: center; padding: 40px 24px; position: relative; }
.login-content { width: min(100%,390px); transform: translateY(-24px); }
.wordmark { display: flex; gap: 14px; align-items: center; justify-content: center; color: var(--fg); } .wordmark h1 { font-size: 60px; letter-spacing: -.06em; }
.tagline { font-size: 15px; color: var(--fg-muted); letter-spacing: .12em; text-align: center; margin-top: 20px; }
form { margin-top: 54px; } .password-line { display: flex; align-items: center; padding: 7px 7px 7px 18px; gap: 8px; background: var(--surface); border: 1px solid var(--border); border-radius: 999px; color: var(--fg-muted); }
.password-line:focus-within { border-color: var(--border-strong); }
input { background: none; border: none; width: 100%; min-width: 0; padding: 5px 0 5px 3px; font-size: 14px; height: 42px; color: var(--fg); } input:focus { outline: none; } input::placeholder { color: var(--fg-faint); }
.enter { background: var(--lime) !important; color: var(--fg) !important; border-color: var(--lime) !important; width: 46px !important; }
.error { color: var(--danger); font-size: 12px; padding: 12px 18px 0; }
.phone { display: flex; align-items: center; justify-content: center; gap: 7px; margin-top: 32px; font-size: 10px; color: var(--fg-muted); } .phone span { margin: 0 3px; }
.help { font-size: 10px; color: var(--fg-muted); text-align: center; margin-top: 18px; } .help summary { cursor: pointer; } .help p { text-align: left; margin-top: 14px; line-height: 1.9; } .license { position: absolute; bottom: 24px; font-size: 9px; color: var(--fg-muted); }
@media (max-width: 680px) { input { font-size: 16px; } .wordmark h1 { font-size: 52px; } }
</style>

import { createApp } from 'vue'
import '@fontsource/inter/latin-400.css'
import '@fontsource/inter/latin-500.css'
import '@fontsource/inter/latin-600.css'
import '@fontsource/instrument-serif/latin-400.css'
import '@fontsource/instrument-serif/latin-400-italic.css'
import './styles/base.css'
import App from './App.vue'
import { router } from './router.js'
import { setUnauthorizedHandler } from './lib/api.js'
import { session } from './lib/store.js'

// 只有 401 才回登录页
setUnauthorizedHandler(() => {
  session.loggedIn = false
  const cur = router.currentRoute.value
  if (cur.name !== 'login') router.replace({ name: 'login', query: { next: cur.fullPath } })
})

createApp(App).use(router).mount('#app')

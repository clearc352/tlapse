import { createRouter, createWebHashHistory } from 'vue-router'
import Login from './views/Login.vue'
import Overview from './views/Overview.vue'
import ProjectForm from './views/ProjectForm.vue'
import Project from './views/Project.vue'
import Logs from './views/Logs.vue'

// 用 hash 路由：资源是 ./assets 相对路径，history 深层路径刷新时
// 相对路径会解析错位；hash 路由在任何子页刷新都能回到同一个 index.html。
// 所有视图打进一个包，手机只需要发 1 个 js + 1 个 css。
export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/login', name: 'login', component: Login, meta: { bare: true, title: '登录' } },
    { path: '/', name: 'overview', component: Overview, meta: { title: '总览' } },
    { path: '/new', name: 'new', component: ProjectForm, meta: { title: '新建项目' } },
    { path: '/p/:id', name: 'project', component: Project, props: true, meta: { title: '项目' } },
    { path: '/p/:id/edit', name: 'edit', component: ProjectForm, props: true, meta: { title: '编辑项目' } },
    { path: '/logs', name: 'logs', component: Logs, meta: { title: '日志' } },
    { path: '/:rest(.*)*', redirect: '/' },
  ],
  scrollBehavior: (to, from, saved) => saved || { top: 0 },
})

router.afterEach((to) => {
  const t = to.meta.title
  document.title = t ? `${t} · tlapse` : 'tlapse'
})

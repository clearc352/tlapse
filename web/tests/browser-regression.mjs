// 使用系统 Chrome + Node 内置 WebSocket，经真实 TLWeb 验证交互；不新增测试依赖。
import { spawn } from 'node:child_process'
import { readFile, writeFile, mkdir, mkdtemp, readdir, copyFile, unlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, basename } from 'node:path'
import { createHash } from 'node:crypto'
import assert from 'node:assert/strict'
import { dateLabel } from '../src/lib/format.js'

const [fixturePath, outputPath] = process.argv.slice(2)
if (!fixturePath || !outputPath) throw Error('用法：node tests/browser-regression.mjs <fixture.json> <证据目录>')
const fixture = JSON.parse(await readFile(fixturePath, 'utf8'))
const origin = `http://127.0.0.1:${fixture.port}`
const output = outputPath
await mkdir(output, { recursive: true })
const profile = await mkdtemp(join(tmpdir(), 'tlapse-chrome-'))
const downloads = join(profile, 'downloads')
await mkdir(downloads)
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', ['--headless=new', '--no-first-run', '--no-default-browser-check', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--autoplay-policy=no-user-gesture-required', 'about:blank'], { stdio: 'ignore' })
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function until(fn, message, timeout = 10000) {
  const start = Date.now()
  while (Date.now() - start < timeout) { const value = await fn(); if (value) return value; await sleep(50) }
  throw Error(`等待超时：${message}`)
}
let ws, seq = 0, pauseHandler = null
const pending = new Map(), downloadEvents = [], events = [], results = [], exceptions = [], csp = [], mediaResponses = [], screenshots = []
const log = (name, details = {}) => { results.push({ name, ...details }); console.log(`PASS ${name}`) }
function command(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++seq
    const timer = setTimeout(() => { pending.delete(id); reject(Error(`CDP 超时 ${method}`)) }, 15000)
    pending.set(id, { resolve, reject, timer })
    ws.send(JSON.stringify({ id, method, params }))
  })
}
async function evaluate(expression) {
  const r = await command('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true })
  if (r.exceptionDetails) throw Error(r.exceptionDetails.text + ': ' + (r.exceptionDetails.exception?.description || expression))
  return r.result.value
}
async function click(selector, text = null) {
  const point = await until(() => evaluate(`(() => { const el = [...document.querySelectorAll(${JSON.stringify(selector)})].find(e => ${text === null ? 'true' : `e.textContent.trim() === ${JSON.stringify(text)}`}); if (!el || el.disabled) return null; el.scrollIntoView({block:'center',inline:'center'}); const r=el.getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2} })()`), `可点击 ${selector} ${text}`)
  assert.ok(point, `可点击 ${selector} ${text}`)
  await command('Input.dispatchMouseEvent', { type: 'mousePressed', button: 'left', clickCount: 1, ...point })
  await command('Input.dispatchMouseEvent', { type: 'mouseReleased', button: 'left', clickCount: 1, ...point })
  await sleep(100)
}
async function fill(selector, value) {
  await evaluate(`(() => { const el=document.querySelector(${JSON.stringify(selector)}); el.focus(); Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(el,${JSON.stringify(value)}); el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true})); })()`)
}
async function route(path) { await evaluate(`location.hash=${JSON.stringify('#' + path)}`); await sleep(300) }
const body = () => evaluate('document.body.innerText')
const tileNames = () => evaluate(`[...document.querySelectorAll('.tile img')].map(e=>decodeURIComponent(new URL(e.src).pathname.split('/').pop())).sort()`)
const activeDate = () => evaluate(`document.querySelector('.chip.on')?.textContent.trim()`)
async function date(day) {
  const expected = dateLabel(day)
  await click('.strip .chip', expected)
  await until(async () => (await activeDate()) === expected && await evaluate(`!document.querySelector('.lib .skeleton')`), `日期 ${day}`)
}
async function photoPage() {
  await route('/p/plant')
  await evaluate(`document.querySelector('.lib')?.scrollIntoView({block:'center'})`)
  await until(async () => (await tileNames()).length > 0, '照片网格')
}
async function selectAll() { await click('.toolbar button', '选择'); await click('.toolbar button', '全选当天') }
async function confirmDelete() {
  await click('.toolbar button', '删除')
  await until(() => evaluate(`!!document.querySelector('[role=alertdialog]')`), '删除确认')
}
async function confirm() { await click('[role=alertdialog] .actions button.solid'); await sleep(350) }
async function screenshot(name) {
  // 截图要等字体和路由/入场动画结束，忽略光点、进度条等无限动画。
  await evaluate('document.fonts.ready')
  if (name !== 'failure') await until(() => evaluate(`!document.querySelector('.toasts .toast')`), '截图前临时提示结束', 12000)
  const finiteAnimations = `document.getAnimations().filter(a => ['running', 'pending'].includes(a.playState) && Number.isFinite(a.effect?.getComputedTiming().endTime)).length`
  await until(async () => (await evaluate(finiteAnimations)) === 0, '截图前有限动画结束')
  await evaluate('new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
  const r = await command('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })
  await writeFile(join(output, `${name}.png`), Buffer.from(r.data, 'base64'))
  screenshots.push({ name, fonts: await evaluate('document.fonts.status'), finiteAnimations: await evaluate(finiteAnimations) })
}
async function intercept(pattern, handler) {
  pauseHandler = handler
  await command('Fetch.enable', { patterns: [{ urlPattern: pattern, requestStage: 'Response' }] })
}
async function stopIntercept() { await command('Fetch.disable'); pauseHandler = null }
const headers = { 'Content-Type': 'application/json', 'X-Tlapse-Request': '1' }
const auth = await fetch(origin + '/api/login', { method: 'POST', headers, body: JSON.stringify({ token: fixture.token }) })
const cookie = auth.headers.get('set-cookie').split(';')[0]
async function api(method, path, data) {
  const r = await fetch(origin + path, { method, headers: { ...headers, Cookie: cookie }, body: data === undefined ? undefined : JSON.stringify(data) })
  return { status: r.status, data: await r.json() }
}
async function resetPhotos() {
  const source = join(fixture.root, 'projects/plant/thumbs/20261114/120005.jpg')
  for (const name of ['130000.jpg','140000.jpg']) for (const kind of ['frames','thumbs']) await unlink(join(fixture.root,'projects/plant',kind,'20261115',name)).catch(e=>{if(e.code!=='ENOENT')throw e})
  for (const day of ['20261114', '20261115']) for (let i = 0; i < 6; i++) for (const kind of ['frames', 'thumbs']) {
    const target = join(fixture.root, 'projects/plant', kind, day, `12000${i}.jpg`)
    await mkdir(join(fixture.root,'projects/plant',kind,day),{recursive:true})
    if (target !== source) await copyFile(source, target)
  }
}
await api('DELETE', '/api/projects/browser-test')
await api('PUT', '/api/projects/plant', { name: '本地豆苗', capture: { shutterSound: true }, encode: { targetDuration: 30 } })
await resetPhotos()
try {
  const debug = await until(async () => { try { return (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0] } catch { return null } }, 'Chrome CDP')
  const pages = await (await fetch(`http://127.0.0.1:${debug}/json/list`)).json()
  ws = new WebSocket(pages.find((p) => p.type === 'page').webSocketDebuggerUrl)
  await new Promise((r, reject) => { ws.onopen = r; ws.onerror = reject })
  ws.onmessage = ({ data }) => {
    const m = JSON.parse(data)
    if (m.id) {
      const p = pending.get(m.id); if (!p) return
      clearTimeout(p.timer); pending.delete(m.id)
      if (m.error) p.reject(Error(JSON.stringify(m.error))); else p.resolve(m.result)
      return
    }
    const p = m.params
    if (/downloadWillBegin$/.test(m.method)) downloadEvents.push(p)
    if (m.method === 'Runtime.exceptionThrown') exceptions.push(p.exceptionDetails)
    if (m.method === 'Log.entryAdded' && /content security policy|violates.*directive/i.test(p.entry.text)) csp.push(p.entry)
    if (m.method === 'Network.requestWillBeSent' && p.request.url.startsWith(origin + '/api/')) events.push({ method: p.request.method, url: p.request.url, body: p.request.postData })
    if (m.method === 'Network.responseReceived' && p.response.mimeType === 'video/mp4') mediaResponses.push({ status: p.response.status, headers: p.response.headers, url: p.response.url })
    if (m.method === 'Fetch.requestPaused') {
      Promise.resolve(pauseHandler?.(p)).then((held) => { if (!held) return command('Fetch.continueRequest', { requestId: p.requestId }) }).catch((e) => { exceptions.push({ text: String(e) }) })
    }
  }
  for (const method of ['Page.enable', 'Network.enable', 'Runtime.enable', 'Log.enable']) await command(method)
  await command('Page.setDownloadBehavior', { behavior: 'allow', downloadPath: downloads })
  await command('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1050, deviceScaleFactor: 1, mobile: false })
  await command('Page.navigate', { url: origin })
  await until(() => evaluate(`!!document.querySelector('#tk')`), '真实服务登录页')
  await fill('#tk', 'bad-local-token')
  await click('form button', '进入控制台')
  await until(async () => (await body()).includes('口令不对'), '401 登录文案')
  await fill('#tk', fixture.token)
  await click('form button', '进入控制台')
  await until(async () => (await body()).includes('本地豆苗'), '登录总览')
  await screenshot('desktop-overview')
  log('桌面登录、错误口令和真实项目总览')

  await click('a[href="#/new"]')
  await until(() => evaluate(`!!document.querySelector('#f-id')`), '新建表单')
  await fill('#f-id', 'browser-test')
  await fill('#f-name', '浏览器临时项目')
  await click('button[type=submit]')
  await until(async () => (await body()).includes('浏览器临时项目') && (await evaluate('location.hash')).includes('/p/browser-test'), '新建项目落库')
  const created = (await api('GET', '/api/projects')).data.projects.find((p) => p.id === 'browser-test')
  assert.equal(created.enabled, false)
  log('浏览器新建项目默认暂停')

  await photoPage()
  await click('a', '编辑参数')
  await until(() => evaluate(`!!document.querySelector('#f-name')`), '编辑表单')
  await fill('#f-name', '本地豆苗已编辑')
  await fill('#f-td', '')
  const beforeEdit = events.length
  await click('button[type=submit]')
  await until(async () => (await evaluate('location.hash')) === '#/p/plant', '编辑保存')
  const edit = events.slice(beforeEdit).find((e) => e.method === 'PUT')
  assert.deepEqual(JSON.parse(edit.body), { name: '本地豆苗已编辑', encode: { targetDuration: null } })
  log('表单仅提交更改字段、null 清空目标时长', { body: JSON.parse(edit.body) })

  const shutterStart = events.length
  await click('[role=switch][aria-label="快门声"]')
  await until(() => events.slice(shutterStart).some((e) => e.method === 'PUT'), '快门声请求')
  assert.deepEqual(JSON.parse(events.slice(shutterStart).find((e) => e.method === 'PUT').body), { capture: { shutterSound: false } })
  await click('.act button', '拍一张')
  await until(async () => (await body()).includes('本地夹具已保存照片') && (await tileNames()).includes('130000.jpg'), '手动拍摄与列表刷新')
  await click('.tile')
  await until(() => evaluate(`document.querySelector('.lb .full')?.complete && document.querySelector('.lb .full')?.naturalWidth === 320`), '大图加载')
  await screenshot('desktop-lightbox')
  await click('.lb button[title="关闭（Esc）"]')
  log('快门局部保存、手动拍摄和大图加载（相机由夹具生成）')

  await date('20261115')
  await selectAll()
  await evaluate(`window.__downloadLinks=[];document.addEventListener('click',e=>{const a=e.target.closest('a[download]');if(a)window.__downloadLinks.push(a.href)},true)`)
  const beforeDownload = downloadEvents.length
  await click('.toolbar button', '下载')
  await date('20261114')
  await sleep(3600)
  const photoDownloads = (downloadEvents.slice(beforeDownload).length ? downloadEvents.slice(beforeDownload).map(e=>e.url) : await evaluate('window.__downloadLinks')).map(url=>({url}))
  assert.ok((await readdir(downloads)).filter(f=>f.endsWith('.jpg')).length >= 6)
  assert.ok(photoDownloads.length >= 6)
  assert.ok(photoDownloads.every((e) => e.url.includes('/20261115/')))
  log('批量下载途中切日期，全部链接固定原日期', { requests: photoDownloads.map((e) => e.url) })

  await date('20261115')
  await click('.toolbar button', '完成')
  // 两次同日列表反序返回：先暂停旧刷新，拍照触发新刷新，再放行旧响应。
  let oldList
  await intercept('*/api/projects/plant/frames?date=*', (p) => { if (!oldList) { oldList = p; return true } return false })
  await click('.toolbar button', '刷新')
  await until(() => oldList, '旧列表响应挂起')
  const extra = join(fixture.root, 'projects/plant/frames/20261115/140000.jpg')
  await copyFile(join(fixture.root, 'projects/plant/frames/20261115/130000.jpg'), extra)
  await copyFile(extra, join(fixture.root, 'projects/plant/thumbs/20261115/140000.jpg'))
  await click('.act button', '拍一张')
  await until(async () => (await tileNames()).includes('140000.jpg'), '新列表先返回')
  await command('Fetch.continueRequest', { requestId: oldList.requestId })
  await sleep(250)
  assert.ok((await tileNames()).includes('140000.jpg'))
  await stopIntercept()
  log('同日重复加载反序返回，旧响应不能覆盖新列表')

  // 打开确认前拍照，确认期间照片刷新并清空选择，确认仍删除发起时快照。
  await selectAll()
  const chosen = await tileNames()
  await click('.act button', '拍一张')
  await confirmDelete()
  const dialogBefore = await evaluate(`document.querySelector('[role=alertdialog]').innerText`)
  await until(() => evaluate(`document.querySelector('.count b')?.textContent === '0'`), '确认期间刷新清空选择')
  const deleteStart = events.length
  const latestBeforeDelete = await evaluate(`document.querySelector('.latest img')?.src`)
  let firstDelete
  await intercept('*/api/projects/plant/frames/20261115/*', (p) => { if (p.request.method === 'DELETE' && !firstDelete) { firstDelete = p; return true } return false })
  await confirm()
  await until(() => firstDelete, '第一删除响应挂起')
  await date('20261114')
  await date('20261115')
  // A→B→A 后重新加载一个尚未删的同名文件，旧操作不得直接修改新视图。
  const beforeRelease = await tileNames()
  await command('Fetch.continueRequest', { requestId: firstDelete.requestId })
  await until(() => events.slice(deleteStart).filter((e) => e.method === 'DELETE').length === chosen.length, '快照全部删除请求')
  await until(async () => (await evaluate(`document.querySelector('.latest img')?.src`)) !== latestBeforeDelete, '同项目切日期后侧栏最新图刷新')
  await sleep(250)
  assert.deepEqual(await tileNames(), beforeRelease)
  const calls = events.slice(deleteStart).filter((e) => e.method === 'DELETE')
  assert.ok(calls.every((e) => e.url.includes('/20261115/')))
  assert.deepEqual(calls.map((e) => decodeURIComponent(e.url.split('/').pop())).sort(), chosen)
  const older = (await api('GET', '/api/projects/plant/frames?date=20261114')).data.frames
  assert.equal(older.length, 6)
  await stopIntercept()
  log('确认期间刷新与A→B→A：请求目标固定，旧结果不改返回后的视图', { dialog: dialogBefore, deletedNames: chosen, olderDayCount: older.length, latestRefreshed: true })

  await resetPhotos()
  await route('/'); await photoPage()
  await selectAll()
  const partialNames = await tileNames()
  let deletes = 0
  await command('Fetch.enable', { patterns: [{ urlPattern: '*/api/projects/plant/frames/20261115/*', requestStage: 'Request' }] })
  pauseHandler = async (p) => {
    if (p.request.method !== 'DELETE') return false
    deletes++
    if (deletes === 2) { await command('Fetch.fulfillRequest', { requestId: p.requestId, responseCode: 500, responseHeaders: [{ name: 'Content-Type', value: 'application/json' }], body: Buffer.from('{"error":"夹具注入删除失败"}').toString('base64') }); return true }
    if (deletes === 3) { await command('Fetch.failRequest', { requestId: p.requestId, errorReason: 'ConnectionReset' }); return true }
    return false
  }
  await confirmDelete(); await confirm()
  await until(async () => (await body()).includes('张未尝试'), '部分失败准确提示')
  assert.equal(deletes, 3)
  const text = await body()
  assert.ok(text.includes('已删除 1 张') && text.includes('2 张失败') && text.includes(`${partialNames.length - 3} 张未尝试`))
  assert.equal(await evaluate('location.hash'), '#/p/plant')
  await stopIntercept()
  log('部分失败与网络中断：实际成功/失败/未尝试分别反馈，不退出登录、不继续删除', { total: partialNames.length, attempted: deletes })

  // 单张确认之后切换/刷新，不复用确认前的数组下标。
  await route('/'); await photoPage()
  const singleName = (await tileNames())[0]
  let singleRefresh
  await intercept('*/api/projects/plant/frames?date=*', p=>{singleRefresh=p;return true})
  await click('.toolbar button', '刷新')
  await until(()=>singleRefresh,'单张确认前刷新响应挂起')
  // 按文件名点击对应照片，而不依赖网格顺序。
  await evaluate(`document.querySelectorAll('.tile').forEach(e => { if (new URL(e.querySelector('img').src).pathname.endsWith(${JSON.stringify('/' + singleName)})) e.dataset.singleTarget='1' })`)
  await click('.tile[data-single-target="1"]')
  await click('.lb button', '删除')
  const singleDialog = await evaluate(`document.querySelector('[role=alertdialog]').innerText`)
  assert.ok(singleDialog.includes(singleName) && singleDialog.includes('2026'))
  await command('Fetch.continueRequest',{requestId:singleRefresh.requestId})
  await until(()=>evaluate(`!document.querySelector('.lb')`),'确认期间刷新关闭旧大图')
  await stopIntercept()
  await confirm()
  await until(async () => !(await tileNames()).includes(singleName), '单张删除按名字移除')
  assert.equal((await api('GET', '/api/projects/plant/frames?date=20261114')).data.frames.length, 6)
  await evaluate(`document.querySelector('.lb button[title="关闭（Esc）"]')?.click()`)
  log('单张删除确认显示日期/文件名，删除目标正确且另一日同名照片保留')

  await click('[role=tab]', '视频')
  await until(() => evaluate(`!!document.querySelector('video')`), '视频面板')
  assert.equal(await evaluate(`document.querySelector('.encode button').disabled`), true)
  assert.equal(await evaluate(`[...document.querySelectorAll('.row-v button')].find(e=>e.textContent.trim()==='上传').disabled`), true)
  await until(() => evaluate(`document.querySelector('video').readyState >= 1`), '视频元信息', 15000)
  const played = await evaluate(`(async()=>{const v=document.querySelector('video'); v.muted=true; await v.play(); await new Promise(r=>setTimeout(r,80)); v.pause(); v.currentTime=v.duration/2; await new Promise(r=>v.addEventListener('seeked',r,{once:true})); return {duration:v.duration,width:v.videoWidth,height:v.videoHeight,currentTime:v.currentTime,error:v.error?.message||null} })()`)
  assert.equal(played.width, 320); assert.equal(played.error, null); assert.ok(played.currentTime > 0)
  const localVideo = await readFile(fixture.video)
  assert.ok(localVideo.length > 20 * 1024 * 1024)
  const res = await fetch(origin + '/api/projects/plant/media/videos/' + basename(fixture.video), { headers: { Cookie: cookie } })
  const remoteVideo = Buffer.from(await res.arrayBuffer())
  assert.equal(createHash('sha256').update(remoteVideo).digest('hex'), createHash('sha256').update(localVideo).digest('hex'))
  await click('.row-v a')
  await until(async () => (await readdir(downloads)).some((f) => f.endsWith('.mp4')), '浏览器下载视频')
  const downloadedName = (await readdir(downloads)).find((f) => f.endsWith('.mp4'))
  assert.equal(createHash('sha256').update(await readFile(join(downloads, downloadedName))).digest('hex'), createHash('sha256').update(localVideo).digest('hex'))
  log('大于20MiB合法H.264视频播放、定位、浏览器下载校验一致，合成/上传能力禁用', { bytes: localVideo.length, sha256: createHash('sha256').update(localVideo).digest('hex'), played })

  await command('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true })
  await route('/p/empty')
  await until(async () => (await body()).includes('还没有照片'), '移动空照片态')
  assert.ok(await evaluate(`document.documentElement.scrollWidth <= innerWidth`))
  await screenshot('mobile-empty-project')
  await route('/logs')
  await until(async () => (await body()).includes('控制台监听'), '真实日志')
  await click('button', '刷新')
  await screenshot('mobile-logs')
  log('390px移动视口照片空态与真实日志刷新，无横向溢出')

  await route('/p/browser-test')
  await until(async () => (await body()).includes('浏览器临时项目'), '临时项目')
  const kept = join(fixture.root, 'projects/browser-test/keep.txt')
  await mkdir(join(fixture.root, 'projects/browser-test'), { recursive: true }); await writeFile(kept, 'retained')
  await click('button[title="删除项目"]')
  assert.ok((await evaluate(`document.querySelector('[role=alertdialog]').innerText`)).includes('不会被删除'))
  await confirm()
  await until(async () => (await evaluate('location.hash')) === '#/', '删除项目返回总览')
  assert.equal(await readFile(kept, 'utf8'), 'retained')
  log('删除项目确认说明保留文件，配置移除后临时文件仍在')

  await resetPhotos()
  await photoPage()
  await click('.tile')
  await until(()=>evaluate(`document.querySelector('.lb .full')?.naturalWidth===320`),'移动大图')
  await screenshot('mobile-lightbox')
  await click('.lb button[title="关闭（Esc）"]')
  await selectAll(); await confirmDelete()
  const authStart=events.length
  await command('Network.clearBrowserCookies')
  await confirm()
  await until(async () => (await evaluate('location.hash')).startsWith('#/login'), '会话失效回登录')
  await until(async () => (await body()).includes('张未尝试'),'会话中断未尝试提示')
  assert.equal(events.slice(authStart).filter(e=>e.method==='DELETE').length,1)
  log('移动照片/大图交互；确认后会话失效仅尝试首项，401回登录并保留未尝试计数')
  assert.equal((await fetch(origin + '/api/projects/plant/media/videos/' + basename(fixture.video))).status, 401)
  await evaluate('document.fonts.ready')
  assert.equal(csp.length, 0)
  assert.equal(exceptions.length, 0)
  log('同源JS/CSS/SVG/字体加载，无CSP阻断或浏览器未处理异常')
} catch (e) {
  await screenshot('failure').catch(() => {})
  results.push({ failure: e.stack, body: await body().catch(() => '') })
  throw e
} finally {
  await writeFile(join(output, 'browser-results.json'), JSON.stringify({ results, csp, exceptions, mediaResponses, downloadEvents, apiRequests: events, screenshots }, null, 2))
  ws?.close(); chrome.kill('SIGTERM')
}

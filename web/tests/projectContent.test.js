import test from 'node:test'
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { mockApi } from '../mock/mock-api.js'

test('删除已暂停项目的照片和视频，但保留项目配置', async () => {
  let middleware
  mockApi().configureServer({ middlewares: { use: (handler) => { middleware = handler } } })
  const server = createServer((req, res) => middleware(req, res, () => res.writeHead(404).end()))
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const base = `http://127.0.0.1:${server.address().port}/api`
  const project = '/projects/mungbean'
  let cookie
  const call = (path, method = 'GET', options = {}) => fetch(base + path, {
    method,
    headers: { 'X-Tlapse-Request': '1', ...(cookie && { Cookie: cookie }), ...options.headers },
    body: options.body,
  })
  try {
    assert.equal((await call(project + '/content', 'DELETE')).status, 401)
    const login = await call('/login', 'POST', { body: JSON.stringify({ token: 'demo' }) })
    assert.equal(login.status, 200)
    cookie = login.headers.get('set-cookie').split(';')[0]
    const getProject = async () => (await (await call('/projects')).json()).projects.find((p) => p.id === 'mungbean')
    const original = await getProject()
    const [date] = (await (await call(project + '/frames')).json()).dates
    const [frame] = (await (await call(project + '/frames?date=' + date)).json()).frames
    assert.ok((await (await call(project + '/videos')).json()).videos.length > 0)

    assert.equal((await call(project + '/resume', 'POST')).status, 200)
    assert.equal((await call(project + '/content', 'DELETE')).status, 409)
    assert.equal((await call(project + '/latest.jpg')).status, 200)
    assert.equal((await call(project + '/pause', 'POST')).status, 200)
    assert.deepEqual(await (await call(project + '/content', 'DELETE')).json(), { deleted: true })
    assert.deepEqual((await (await call(project + '/frames')).json()).dates, [])
    assert.deepEqual((await (await call(project + '/videos')).json()).videos, [])
    assert.equal((await call(project + '/latest.jpg')).status, 404)
    assert.equal((await call(`${project}/media/frames/${date}/${frame.name}`)).status, 404)
    const cleared = await getProject()
    assert.deepEqual(cleared.capture, original.capture)
    assert.deepEqual(cleared.encode, original.encode)
    assert.equal(cleared.state.frameCount, 0)
  } finally {
    server.closeAllConnections()
    await new Promise((resolve) => server.close(resolve))
  }
})

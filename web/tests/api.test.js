import test from 'node:test'
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { request } from '../src/lib/api.js'

test('响应体中断不能被当成删除成功；超时覆盖响应体读取', async () => {
  const server = createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': '1000' })
    res.write('{"deleted":')
    if (req.url === '/broken') setTimeout(() => res.destroy(), 20)
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const base = `http://127.0.0.1:${server.address().port}`
  try {
    await assert.rejects(request('DELETE', base + '/broken'), (error) => error.kind === 'network' && /结果尚未确认/.test(error.message))
    await assert.rejects(request('DELETE', base + '/stalled', undefined, { timeout: 50 }), (error) => error.kind === 'timeout')
  } finally {
    server.closeAllConnections()
    await new Promise((resolve) => server.close(resolve))
  }
})

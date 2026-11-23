import test from 'node:test'
import assert from 'node:assert/strict'
import { photoSnapshot, deletePhotos, deletionMessage } from '../src/lib/photoOperations.js'
import { emptyForm, fromProject, toBody, diffBody } from '../src/lib/projectForm.js'

test('确认期间切项目/日期或刷新选择，不改变删除快照', async () => {
  const names = ['120000.jpg', '120001.jpg']
  const snapshot = photoSnapshot('plant', '20261115', names)
  names.splice(0, 2, 'other.jpg')
  const calls = []
  await deletePhotos(snapshot, async (...args) => { calls.push(args); await Promise.resolve() })
  assert.deepEqual(calls, [['plant', '20261115', '120000.jpg'], ['plant', '20261115', '120001.jpg']])
  assert.ok(Object.isFrozen(snapshot.names))
})

test('404、可继续的失败、中断和未尝试项分别计数', async () => {
  const snapshot = photoSnapshot('plant', '20261115', ['a', 'b', 'c', 'd', 'e'])
  const calls = []
  const result = await deletePhotos(snapshot, async (_id, _date, name) => {
    calls.push(name)
    if (name === 'b') throw { status: 404 }
    if (name === 'c') throw { status: 500, kind: 'http', message: '写入失败' }
    if (name === 'd') throw { kind: 'network', message: '连接中断' }
  })
  assert.deepEqual(calls, ['a', 'b', 'c', 'd'])
  assert.deepEqual(result.deleted, ['a'])
  assert.deepEqual(result.missing, ['b'])
  assert.deepEqual(result.failed.map((f) => f.name), ['c', 'd'])
  assert.deepEqual(result.unattempted, ['e'])
  assert.match(deletionMessage(result), /已删除 1 张，1 张原本不存在，2 张失败.*1 张未尝试/)
})

for (const kind of ['auth', 'timeout']) test(`${kind} 后停止删除，不重放后续项`, async () => {
  let count = 0
  const result = await deletePhotos(photoSnapshot('plant', '20261115', ['a', 'b']), async () => {
    count++; throw { kind, message: kind }
  })
  assert.equal(count, 1)
  assert.equal(result.deleted.length, 0)
  assert.deepEqual(result.unattempted, ['b'])
})

test('新建默认暂停，表单无改动为空补丁、清空时长发 null、改快门不覆盖其它字段', () => {
  assert.equal(toBody(emptyForm()).enabled, false)
  const form = fromProject({ id: 'plant', name: '豆苗', capture: { interval: 60 }, encode: { targetDuration: 30 } })
  const original = toBody(form)
  assert.deepEqual(diffBody(original, toBody(form)), {})
  form.targetDuration = ''
  form.shutterSound = false
  assert.deepEqual(diffBody(original, toBody(form)), { capture: { shutterSound: false }, encode: { targetDuration: null } })
})

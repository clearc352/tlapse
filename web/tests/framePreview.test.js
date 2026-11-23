import { test } from 'node:test'
import assert from 'node:assert/strict'
import { sampleFrames, scrubIndex } from '../src/lib/framePreview.js'
test('contact sheets stay bounded and include both ends, even for large days', () => {
  assert.deepEqual(sampleFrames(0), [])
  assert.deepEqual(sampleFrames(1), [0])
  assert.deepEqual(sampleFrames(3), [0, 1, 2])
  const samples = sampleFrames(100000)
  assert.equal(samples.length, 9)
  assert.equal(new Set(samples).size, 9)
  assert.equal(samples[0], 0)
  assert.equal(samples.at(-1), 99999)
})
test('dragging scrubs in either direction and clamps at day boundaries', () => {
  assert.equal(scrubIndex(5, -50, 100, 11), 10)
  assert.equal(scrubIndex(5, 50, 100, 11), 0)
  assert.equal(scrubIndex(2, 500, 100, 11), 0)
  assert.equal(scrubIndex(2, -500, 100, 11), 10)
  assert.equal(scrubIndex(0, -500, 100, 1), 0)
  assert.equal(scrubIndex(0, -500, 0, 0), 0)
})

<script setup>
import { ref, computed, onMounted } from 'vue'
import { useRouter, onBeforeRouteLeave } from 'vue-router'
import { api } from '../lib/api.js'
import { toast, toastError, confirmDialog } from '../lib/store.js'
import { emptyForm, fromProject, toBody, diffBody, validate, ORIENTATIONS } from '../lib/projectForm.js'
import { interval as fmtInterval, duration } from '../lib/format.js'
import Icon from '../components/Icon.vue'

const props = defineProps({ id: String })
const router = useRouter()
const isNew = computed(() => !props.id)

const form = ref(emptyForm())
const original = ref(null) // 编辑时：载入时的接口形态，用来算差异
const loaded = ref(isNew.value)
const saving = ref(false)
const touched = ref(false)
const serverErr = ref('')

onMounted(async () => {
  if (isNew.value) { original.value = toBody(form.value); return }
  try {
    const list = await api.projects()
    const p = list.find((x) => x.id === props.id)
    if (!p) { toast(`找不到项目 ${props.id}`, 'danger'); router.replace('/'); return }
    form.value = fromProject(p)
    original.value = toBody(form.value)
    loaded.value = true
  } catch (e) { toastError(e) }
})

const errors = computed(() => validate(form.value, isNew.value))
const showErr = (k) => touched.value && errors.value[k]
const hasErrors = computed(() => Object.keys(errors.value).length > 0)
const pending = computed(() => (original.value ? diffBody(original.value, toBody(form.value)) : {}))
const dirty = computed(() => isNew.value ? true : Object.keys(pending.value).length > 0)

// 分辨率：预设 / full / 自定义
const RES = ['1920x1440', '1440x1080', '1280x960', 'full']
const resCustom = ref(false)
const resMode = computed({
  get: () => (resCustom.value || !RES.includes(form.value.resolution) ? 'custom' : form.value.resolution),
  set: (v) => { if (v === 'custom') { resCustom.value = true } else { resCustom.value = false; form.value.resolution = v } },
})
const INTERVALS = [[10, '10 秒'], [30, '30 秒'], [60, '1 分'], [300, '5 分'], [900, '15 分'], [3600, '1 小时']]

// —— 估算 ——
function minutes(hhmm) { const [h, m] = hhmm.split(':').map(Number); return h * 60 + m }
const nightMinutes = computed(() => {
  const f = form.value
  let a, b
  if (f.nightMode === 'default') { a = 22 * 60; b = 6 * 60 }
  else if (f.nightMode === 'custom' && !errors.value.night) { a = minutes(f.nightFrom); b = minutes(f.nightTo) }
  else return 0
  return b > a ? b - a : 1440 - a + b
})
const perDay = computed(() => {
  const iv = Number(form.value.interval)
  if (!(iv >= 5)) return 0
  return Math.floor(((1440 - nightMinutes.value) * 60) / iv)
})
const mbPerShot = computed(() => {
  // 实测 1440×1920、质量 0.85 约 686KB；按像素和质量粗略缩放
  const r = form.value.resolution
  const px = r === 'full' ? 3264 * 2448 : (() => { const [w, h] = r.split('x').map(Number); return w * h || 1920 * 1440 })()
  const q = Number(form.value.jpegQuality) || 0.85
  return 0.686 * (px / (1920 * 1440)) * (0.35 + 0.65 * (q / 0.85))
})
const dayVideo = computed(() => perDay.value / (Number(form.value.fps) || 30))
const td = computed(() => Number(form.value.targetDuration) || 0)
const summary = computed(() => {
  const f = form.value
  const lines = []
  lines.push(['每天约', `${perDay.value.toLocaleString()} 张`])
  lines.push(['素材长度', `约 ${duration(dayVideo.value)} / 天`])
  if (f.mode === 'cumulative') lines.push(['成片', td.value ? `抽帧到约 ${td.value} 秒` : `每天增加约 ${duration(dayVideo.value)}`])
  else lines.push(['成片', td.value ? `约 ${Math.min(td.value, dayVideo.value).toFixed(1)} 秒` : `约 ${duration(dayVideo.value)}`])
  lines.push(['占用', `约 ${(perDay.value * mbPerShot.value).toFixed(0)} MB / 天`])
  const keep = Number(f.keepFramesDays) || 0
  if (keep) lines.push(['保留期内', `约 ${((perDay.value * mbPerShot.value * keep) / 1024).toFixed(1)} GB`])
  return lines
})

function toggleUpload(t) {
  const u = form.value.upload
  const i = u.indexOf(t)
  i >= 0 ? u.splice(i, 1) : u.push(t)
}

async function save() {
  touched.value = true
  serverErr.value = ''
  if (hasErrors.value) {
    toast('有几项需要改一下', 'warn')
    requestAnimationFrame(() => document.querySelector('.err')?.scrollIntoView({ block: 'center', behavior: 'smooth' }))
    return
  }
  if (!isNew.value && !dirty.value) { router.push({ name: 'project', params: { id: props.id } }); return }
  saving.value = true
  try {
    if (isNew.value) {
      const body = toBody(form.value, { includeId: true })
      await api.createProject(body)
      toast(`已创建「${body.name}」${body.enabled ? '' : '，目前是暂停状态'}`, 'ok')
      leaving = true
      router.replace({ name: 'project', params: { id: body.id } })
    } else {
      await api.updateProject(props.id, pending.value)
      toast('已保存', 'ok')
      leaving = true
      router.push({ name: 'project', params: { id: props.id } })
    }
  } catch (e) {
    if (e.kind === 'http' || e.kind === 'forbidden') serverErr.value = e.message
    toastError(e)
  } finally { saving.value = false }
}

let leaving = false
onBeforeRouteLeave(async () => {
  if (leaving || !loaded.value) return true
  const changed = isNew.value ? (form.value.id || form.value.name) : dirty.value
  if (!changed) return true
  return await confirmDialog({ title: '放弃没保存的修改？', body: '离开这个页面后，表单里的改动不会保存到手机。', confirmText: '放弃修改', tone: 'danger' })
})
function cancel() { router.back() }
</script>

<template>
  <div class="shell page">
    <nav class="crumb">
      <router-link :to="isNew ? '/' : { name: 'project', params: { id } }" class="back"><Icon name="arrowLeft" size="14" />{{ isNew ? '总览' : '返回项目' }}</router-link>
    </nav>
    <header class="head rise">
      <span v-if="!isNew" class="eyebrow">编辑参数</span>
      <h1 class="display h-xl">
        <template v-if="isNew">新建项目</template>
        <template v-else>{{ form.name || id }}</template>
      </h1>
    </header>

    <div v-if="!loaded" class="skeleton" style="height: 480px"></div>

    <form v-else class="layout" @submit.prevent="save" novalidate>
      <div class="sections">
        <p v-if="serverErr" class="server-err"><Icon name="alert" size="16" />{{ serverErr }}</p>

        <!-- 01 基本 -->
        <section class="sec">
          <div class="sec-h"><h2 class="display h-md">基本</h2></div>
          <div class="grid2">
            <div class="field">
              <label for="f-id">id</label>
              <input id="f-id" class="input mono" v-model.trim="form.id" :disabled="!isNew" :class="{ bad: showErr('id') }" placeholder="mungbean" spellcheck="false" autocomplete="off" />
              <p v-if="showErr('id')" class="err">{{ errors.id }}</p>
              <p v-else class="hint">{{ isNew ? '用作文件夹名，创建后不能再改。' : '创建之后不能修改。' }}</p>
            </div>
            <div class="field">
              <label for="f-name">名称</label>
              <input id="f-name" class="input" v-model="form.name" :class="{ bad: showErr('name') }" placeholder="绿豆发芽" maxlength="80" />
              <p v-if="showErr('name')" class="err">{{ errors.name }}</p>
            </div>
          </div>
          <div class="toggle-row">
            <div>
              <div class="label">按时自动拍摄</div>
              <p class="hint">{{ isNew ? '新建项目默认关闭，建议先手动拍几张确认构图再打开。' : '关掉等于暂停，手动拍照不受影响。' }}</p>
            </div>
            <button type="button" class="switch" role="switch" :aria-checked="form.enabled" @click="form.enabled = !form.enabled" aria-label="按时自动拍摄"></button>
          </div>
        </section>

        <!-- 02 拍摄 -->
        <section class="sec">
          <div class="sec-h"><h2 class="display h-md">拍摄</h2></div>
          <div class="field">
            <label for="f-iv">间隔</label>
            <div class="row gap-12 wrap">
              <div class="input-unit" style="width: 160px"><input id="f-iv" class="input num" type="number" min="5" max="86400" step="1" v-model.number="form.interval" :class="{ bad: showErr('interval') }" /><span class="unit">秒</span></div>
              <div class="seg">
                <button v-for="[v, t] in INTERVALS" :key="v" type="button" :class="{ on: form.interval === v }" @click="form.interval = v">{{ t }}</button>
              </div>
            </div>
            <p v-if="showErr('interval')" class="err">{{ errors.interval }}</p>
            <p v-else class="hint">{{ fmtInterval(form.interval) }}拍一张。5 秒到 1 天之间。</p>
          </div>

          <div class="grid2">
            <div class="field">
              <label for="f-res">分辨率</label>
              <select id="f-res" class="select" v-model="resMode">
                <option value="1920x1440">1920×1440（推荐）</option>
                <option value="1440x1080">1440×1080</option>
                <option value="1280x960">1280×960</option>
                <option value="full">full · 传感器全尺寸</option>
                <option value="custom">自定义…</option>
              </select>
              <input v-if="resMode === 'custom'" class="input mono" v-model.trim="form.resolution" placeholder="宽x高，例如 1600x1200" :class="{ bad: showErr('resolution') }" />
              <p v-if="showErr('resolution')" class="err">{{ errors.resolution }}</p>
            </div>
            <div class="field">
              <label for="f-settle">对焦稳定时间</label>
              <div class="input-unit"><input id="f-settle" class="input num" type="number" min="0.3" max="5" step="0.1" v-model.number="form.settleSeconds" :class="{ bad: showErr('settleSeconds') }" /><span class="unit">秒</span></div>
              <p v-if="showErr('settleSeconds')" class="err">{{ errors.settleSeconds }}</p>
              <p v-else class="hint">打开摄像头后等多久再按快门，0.3–5 秒。</p>
            </div>
          </div>

          <div class="field">
            <span class="label">方向</span>
            <div class="ori">
              <button v-for="o in ORIENTATIONS" :key="o.v" type="button" class="ori-b" :class="{ on: form.orientation === o.v }" @click="form.orientation = o.v">
                <span class="phone" :class="o.v"><i></i></span>
                <span class="t">{{ o.t }}</span>
                <span class="d">{{ o.d }}</span>
              </button>
            </div>
            <p class="hint">手机平放时重力判断不准，请改成明确方向。</p>
          </div>

          <div class="field">
            <label for="f-q">JPEG 质量 <span class="muted num">{{ Number(form.jpegQuality).toFixed(2) }}</span></label>
            <input id="f-q" type="range" class="range" min="0.1" max="1" step="0.01" v-model.number="form.jpegQuality" :style="{ '--fill': ((form.jpegQuality - 0.1) / 0.9 * 100) + '%' }" />
            <p class="hint">0.85 时 1440×1920 一张约 690 KB。越高越清晰，也越占空间。</p>
          </div>

          <div class="toggles">
            <label class="tg"><span><b>快门声</b><small>关掉后只请求静音；不支持时会报错</small></span><button type="button" class="switch" role="switch" :aria-checked="form.shutterSound" @click="form.shutterSound = !form.shutterSound"></button></label>
            <label class="tg"><span><b>锁定对焦</b><small>每张焦点一致，避免画面呼吸</small></span><button type="button" class="switch" role="switch" :aria-checked="form.lockFocus" @click="form.lockFocus = !form.lockFocus"></button></label>
            <label class="tg"><span><b>锁定曝光</b><small>减少帧间闪烁</small></span><button type="button" class="switch" role="switch" :aria-checked="form.lockExposure" @click="form.lockExposure = !form.lockExposure"></button></label>
            <label class="tg"><span><b>锁定白平衡</b><small>色调保持一致</small></span><button type="button" class="switch" role="switch" :aria-checked="form.lockWhiteBalance" @click="form.lockWhiteBalance = !form.lockWhiteBalance"></button></label>
          </div>
        </section>

        <!-- 03 夜间 -->
        <section class="sec">
          <div class="sec-h"><h2 class="display h-md">夜间跳过</h2></div>
          <div class="seg">
            <button type="button" :class="{ on: form.nightMode === 'off' }" @click="form.nightMode = 'off'">关闭</button>
            <button type="button" :class="{ on: form.nightMode === 'default' }" @click="form.nightMode = 'default'">默认 22:00–06:00</button>
            <button type="button" :class="{ on: form.nightMode === 'custom' }" @click="form.nightMode = 'custom'">自定义</button>
          </div>
          <div v-if="form.nightMode === 'custom'" class="grid3">
            <div class="field"><label for="f-nf">从</label><input id="f-nf" class="input num" type="time" v-model="form.nightFrom" :class="{ bad: showErr('night') }" /></div>
            <div class="field"><label for="f-nt">到</label><input id="f-nt" class="input num" type="time" v-model="form.nightTo" :class="{ bad: showErr('night') }" /></div>
            <div class="field"><label for="f-nb">太暗丢弃阈值</label><input id="f-nb" class="input num" type="number" min="0" max="1" step="0.01" placeholder="留空 = 不丢弃" v-model="form.nightBrightness" :class="{ bad: showErr('nightBrightness') }" /></div>
          </div>
          <p v-if="showErr('night')" class="err">{{ errors.night }}</p>
          <p v-if="showErr('nightBrightness')" class="err">{{ errors.nightBrightness }}</p>
          <p class="hint">时段内不做定时拍摄。阈值大于 0 时，拍完后平均亮度低于它的照片会被丢弃（例如 0.08）。手动拍照不看时段，但太暗仍可能被丢弃。</p>
        </section>

        <!-- 04 合成 -->
        <section class="sec">
          <div class="sec-h"><h2 class="display h-md">合成视频</h2></div>
          <div class="grid2">
            <div class="field">
              <span class="label">周期</span>
              <div class="row gap-8 wrap">
                <div class="seg">
                  <button type="button" :class="{ on: form.everyMode === 'daily' }" @click="form.everyMode = 'daily'">每天</button>
                  <button type="button" :class="{ on: form.everyMode === 'weekly' }" @click="form.everyMode = 'weekly'">每周</button>
                  <button type="button" :class="{ on: form.everyMode === 'days' }" @click="form.everyMode = 'days'">每 N 天</button>
                </div>
                <div v-if="form.everyMode === 'days'" class="input-unit" style="width: 110px"><input class="input num" type="number" min="1" max="366" v-model.number="form.everyDays" :class="{ bad: showErr('every') }" aria-label="天数" /><span class="unit">天</span></div>
              </div>
              <p v-if="showErr('every')" class="err">{{ errors.every }}</p>
            </div>
            <div class="field">
              <label for="f-at">时刻</label>
              <input id="f-at" class="input num" v-model.trim="form.at" placeholder="23:30" :class="{ bad: showErr('at') }" style="max-width: 160px" />
              <p v-if="showErr('at')" class="err">{{ errors.at }}</p>
              <p v-else class="hint">HH:MM，小时可以是一位，例如 0:10。</p>
            </div>
          </div>
          <div class="field">
            <span class="label">范围</span>
            <div class="cards2">
              <button type="button" class="opt" :class="{ on: form.mode === 'daily' }" @click="form.mode = 'daily'"><b>当天</b><small>只用当天的照片，每天一条短片</small></button>
              <button type="button" class="opt" :class="{ on: form.mode === 'cumulative' }" @click="form.mode = 'cumulative'"><b>累计</b><small>用全部照片，从第一天到现在一条片子</small></button>
            </div>
          </div>
          <div class="grid2">
            <div class="field">
              <span class="label">帧率</span>
              <div class="seg">
                <button v-for="v in [24, 30, 60]" :key="v" type="button" :class="{ on: form.fps === v }" @click="form.fps = v">{{ v }} fps</button>
              </div>
            </div>
            <div class="field">
              <label for="f-td">目标时长</label>
              <div class="input-unit" style="max-width: 200px"><input id="f-td" class="input num" type="number" min="1" max="600" step="1" placeholder="不抽帧" v-model="form.targetDuration" :class="{ bad: showErr('targetDuration') }" /><span class="unit">秒</span></div>
              <p v-if="showErr('targetDuration')" class="err">{{ errors.targetDuration }}</p>
              <p v-else class="hint">照片太多时抽帧压到这个时长，留空表示不抽帧。</p>
            </div>
          </div>
        </section>

        <!-- 05 清理与上传 -->
        <section class="sec">
          <div class="sec-h"><h2 class="display h-md">清理与上传</h2></div>
          <div class="field">
            <label for="f-keep">保留原图</label>
            <div class="input-unit" style="max-width: 160px"><input id="f-keep" class="input num" type="number" min="0" max="3650" v-model.number="form.keepFramesDays" :class="{ bad: showErr('keepFramesDays') }" /><span class="unit">天</span></div>
            <p v-if="showErr('keepFramesDays')" class="err">{{ errors.keepFramesDays }}</p>
            <p v-else class="hint">合成成功之后，才会删除早于这个天数的原图和缩略图。</p>
          </div>
          <div class="field">
            <span class="label">上传目标</span>
            <div class="row gap-24 wrap">
              <label class="check"><input type="checkbox" :checked="form.upload.includes('telegram')" @change="toggleUpload('telegram')" />Telegram</label>
              <label class="check"><input type="checkbox" :checked="form.upload.includes('webdav')" @change="toggleUpload('webdav')" />WebDAV</label>
            </div>
            <p class="hint">这里只选这个项目用哪些目标。勾上之后，还要在手机的 config.json 的 uploads 里启用对应账号才会真正上传；账号和密码不在网页上显示，也不能在这里改。</p>
          </div>
        </section>
      </div>

      <!-- 右侧：估算 + 保存 -->
      <aside class="side">
        <div class="sticky">
          <div class="est panel">
            <span class="eyebrow">按这样设置</span>
            <dl>
              <div v-for="[k, v] in summary" :key="k"><dt>{{ k }}</dt><dd class="num">{{ v }}</dd></div>
            </dl>
            <p class="faint small">粗略估算，实际大小随画面内容变化。</p>
          </div>
          <div class="save">
            <button type="submit" class="btn foil lg wide" :disabled="saving || (!isNew && !dirty)">
              <span v-if="saving" class="spinner"></span><Icon v-else name="check" />{{ isNew ? '创建项目' : dirty ? '保存修改' : '没有改动' }}
            </button>
            <button type="button" class="btn lg wide ghost" @click="cancel">取消</button>
            <p v-if="!isNew && dirty" class="faint small">只会提交改动过的 {{ Object.keys(pending).length }} 组字段，其余保持手机上的原样。</p>
          </div>
        </div>
      </aside>
    </form>
  </div>
</template>

<style scoped>
.page { padding-top: 28px; }
.crumb { margin-bottom: 28px; }
.back { display: inline-flex; align-items: center; gap: 6px; font-size: 13.5px; color: var(--fg-muted); }
.back:hover { color: var(--fg); }
.head { margin-bottom: 40px; }
.head h1 { margin-top: 10px; }
.layout { display: grid; grid-template-columns: 1fr 320px; gap: clamp(24px, 4vw, 64px); align-items: start; }
.sections { display: flex; flex-direction: column; min-width: 0; }
.sec { display: flex; flex-direction: column; gap: 22px; padding: 32px 0; border-top: 1px solid var(--rule); }
.sec:first-of-type, .server-err + .sec { border-top: 0; padding-top: 0; }
.sec-h { display: flex; align-items: baseline; gap: 14px; }
.sec-h .n { font-family: var(--font-mono); font-size: 12px; color: var(--accent-ink); }
.grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
.grid3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; }
.server-err { display: flex; gap: 10px; align-items: center; padding: 12px 16px; margin-bottom: 24px; border-radius: var(--r-md); background: var(--danger-soft); color: var(--danger); font-size: 14px; }
.toggle-row { display: flex; align-items: center; justify-content: space-between; gap: 20px; padding: 16px 18px; border: 1px solid var(--border); border-radius: var(--r-md); background: var(--surface); }
.toggle-row .label { font-size: 14px; color: var(--fg); font-weight: 500; }
.toggles { display: grid; grid-template-columns: 1fr 1fr; gap: 1px; background: var(--rule); border: 1px solid var(--rule); border-radius: var(--r-md); overflow: hidden; }
.tg { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 14px 16px; background: var(--surface); cursor: pointer; }
.tg span { display: flex; flex-direction: column; }
.tg b { font-weight: 500; font-size: 14px; color: var(--fg); }
.tg small { font-size: 12px; color: var(--fg-muted); }
.ori { display: grid; grid-template-columns: repeat(6, 1fr); gap: 8px; }
.ori-b { display: flex; flex-direction: column; align-items: center; gap: 4px; padding: 14px 6px 12px; border: 1px solid var(--border); border-radius: var(--r-md); background: var(--surface); color: var(--fg-muted); cursor: pointer; transition: all var(--dur-2); text-align: center; }
.ori-b:hover { border-color: var(--border-strong); color: var(--fg); }
.ori-b.on { border-color: var(--accent); background: var(--accent-soft); color: var(--fg); }
.ori-b .t { font-size: 13px; color: inherit; }
.ori-b .d { font-size: 11px; color: var(--fg-faint); line-height: 1.3; }
.phone { position: relative; width: 18px; height: 30px; border: 1.5px solid currentColor; border-radius: 4px; margin-bottom: 6px; transition: transform var(--dur-4) var(--ease-spring); }
.phone i { position: absolute; left: 50%; bottom: 2px; width: 4px; height: 4px; margin-left: -2px; border-radius: 50%; border: 1px solid currentColor; }
.phone.auto, .phone.raw { border-style: dashed; }
.phone.portraitUpsideDown { transform: rotate(180deg); }
.phone.landscapeHomeRight { transform: rotate(-90deg); }
.phone.landscapeHomeLeft { transform: rotate(90deg); }
.cards2 { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
.opt { display: flex; flex-direction: column; gap: 4px; padding: 14px 16px; text-align: left; border: 1px solid var(--border); border-radius: var(--r-md); background: var(--surface); color: var(--fg); cursor: pointer; transition: all var(--dur-2); }
.opt b { font-weight: 500; font-size: 14px; }
.opt small { font-size: 12.5px; color: var(--fg-muted); }
.opt.on { border-color: var(--accent); background: var(--accent-soft); }
.opt:hover:not(.on) { border-color: var(--border-strong); }
.err { color: var(--danger); font-size: 12.5px; }
.side .sticky { position: sticky; top: calc(var(--topbar-h) + var(--frame) + 24px); display: flex; flex-direction: column; gap: 16px; }
.est { padding: 20px; display: flex; flex-direction: column; gap: 12px; }
.est dl { margin: 0; }
.est dl div { display: flex; justify-content: space-between; gap: 12px; padding: 8px 0; border-bottom: 1px solid var(--rule); font-size: 13.5px; }
.est dt { color: var(--fg-muted); }
.est dd { margin: 0; color: var(--fg); text-align: right; }
.small { font-size: 12px; }
.save { display: flex; flex-direction: column; gap: 8px; }
.wide { width: 100%; }
@media (max-width: 960px) {
  .layout { grid-template-columns: 1fr; }
  .side .sticky { position: static; }
  .save { position: fixed; left: var(--rail); right: 0; bottom: 0; z-index: 60; flex-direction: row; align-items: center; padding: 12px var(--gutter) calc(12px + env(safe-area-inset-bottom)); background: var(--bg); border-top: 1px solid var(--rule); }
  .save .small { display: none; }
  .save .ghost { width: auto; }
  .sections { padding-bottom: 100px; }
  .ori { grid-template-columns: repeat(3, 1fr); }
}
@media (max-width: 600px) { .grid2, .grid3, .toggles, .cards2 { grid-template-columns: 1fr; } }
@media (max-width: 680px) { .save { left: 0; bottom: calc(68px + env(safe-area-inset-bottom)); padding-bottom: 12px; } }
</style>

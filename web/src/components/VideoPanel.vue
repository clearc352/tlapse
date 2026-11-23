<script setup>
import { ref, computed, onMounted, watch } from 'vue'
import { api, media } from '../lib/api.js'
import { toast, toastError } from '../lib/store.js'
import { device } from '../lib/device.js'
import { dateLong, videoMeta } from '../lib/format.js'
import Icon from './Icon.vue'
import VideoPlayer from './VideoPlayer.vue'

const props = defineProps({ project: Object, refreshKey: Number })
const emit = defineEmits(['encoded', 'count'])

const videos = ref(null)
const encodeEnabled = ref(true)
const playing = ref('')
const encoding = ref(false)
const uploading = ref('')
const last = ref(null)

const canEncode = computed(() => device.data?.features?.encode !== false && encodeEnabled.value)
const canUpload = computed(() => device.data?.features?.upload !== false)
const targets = computed(() => props.project?.upload || [])

async function load() {
  try {
    const r = await api.videos(props.project.id)
    // 文件名里带日期，新的在前
    videos.value = (r.videos || []).slice().sort((a, b) => b.name.localeCompare(a.name))
    encodeEnabled.value = r.encodeEnabled !== false
    emit('count', videos.value.length)
    if (!playing.value && videos.value[0]) playing.value = videos.value[0].name
  } catch (e) { toastError(e); if (videos.value === null) videos.value = [] }
}
onMounted(load)
watch(() => props.refreshKey, load)

async function encodeNow() {
  if (encoding.value) return
  encoding.value = true
  last.value = null
  try {
    const r = await api.encode(props.project.id)
    last.value = r
    toast(`${r.message || '已合成'} · ${r.frames} 帧 · ${r.width}×${r.height}`, 'ok', 7000)
    if (r.removedFrames > 0) toast(`按保留天数清理了 ${r.removedFrames} 张旧原图`, 'warn', 8000)
    const name = (r.relativePath || '').split('/').pop()
    await load()
    if (name) playing.value = name
    emit('encoded')
  } catch (e) {
    if (e.status === 409) toast(e.message || '还没有照片可以合成', 'warn')
    else if (e.kind === 'network' || e.kind === 'timeout') toast('合成过程中连接中断。手机可能还在合成，稍后刷新视频列表看看。', 'warn', 8000)
    else toastError(e)
  } finally { encoding.value = false }
}

async function upload(name) {
  if (uploading.value) return
  uploading.value = name
  try {
    const r = await api.upload(name)
    toast(r.message || '已上传', r.ok === false ? 'warn' : 'ok', 7000)
  } catch (e) {
    if (e.status === 409) toast(e.message || '多个项目有同名视频，无法确定上传哪一个', 'warn', 7000)
    else toastError(e)
  } finally { uploading.value = '' }
}
</script>

<template>
  <section class="vp">
    <div class="encode panel">
      <div class="grow">
        <span class="eyebrow">合成</span>
        <p class="txt">
          <template v-if="!canEncode">当前进程没有合成能力，无法在这里合成视频。</template>
          <template v-else>把{{ project.encode?.mode === 'cumulative' ? '全部照片' : '当天的照片' }}合成为 {{ project.encode?.fps || 30 }} fps 视频<template v-if="project.encode?.targetDuration">，抽帧到约 {{ project.encode.targetDuration }} 秒</template>。可能要几分钟，期间手机会比较忙。</template>
        </p>
        <p class="txt warn" v-if="canEncode">合成成功后，早于 {{ project.cleanup?.keepFramesDays ?? 14 }} 天的原图和缩略图会被清理。</p>
      </div>
      <button class="btn foil lg" :disabled="!canEncode || encoding" @click="encodeNow">
        <span v-if="encoding" class="spinner"></span><Icon v-else name="film" />{{ encoding ? '正在合成…' : '立刻合成' }}
      </button>
    </div>

    <div v-if="encoding" class="progress"><i></i></div>

    <div v-if="videos === null" class="skeleton" style="height: 240px; margin-top: 20px"></div>
    <div v-else-if="!videos.length" class="empty" style="margin-top: 20px">
      <p class="display">还没有视频</p>
      <p>到了设定的合成时间会自动生成，也可以现在点「立刻合成」。</p>
    </div>
    <div v-else class="list">
      <article v-for="v in videos" :key="v.name" class="vid" :class="{ on: playing === v.name }">
        <div class="player" v-if="playing === v.name">
          <VideoPlayer :src="media.video(project.id, v.name)" :name="v.name" />
        </div>
        <div class="row-v">
          <button class="name" @click="playing = playing === v.name ? '' : v.name">
            <Icon :name="playing === v.name ? 'film' : 'play'" size="16" />
            <span class="grow">
              <span class="mono n">{{ v.name }}</span>
              <span class="muted sub" v-if="videoMeta(v.name).date">{{ dateLong(videoMeta(v.name).date) }}<template v-if="videoMeta(v.name).mode"> · {{ videoMeta(v.name).mode }}</template></span>
            </span>
          </button>
          <a class="btn sm" :href="media.video(project.id, v.name)" :download="v.name"><Icon name="download" size="14" />下载</a>
          <button class="btn sm" :disabled="!canUpload || !!uploading" @click="upload(v.name)" :title="canUpload ? (targets.length ? '上传到：' + targets.join('、') : '这个项目没有勾选上传目标') : '当前进程没有上传能力'">
            <span v-if="uploading === v.name" class="spinner"></span><Icon v-else name="upload" size="14" />上传
          </button>
        </div>
      </article>
      <p class="faint foot">上传目标要在 config.json 的 uploads 里启用账号才会真正发出；没有可用目标时会按手机返回的说明提示。</p>
    </div>
  </section>
</template>

<style scoped>
.encode { display: flex; align-items: center; gap: 24px; padding: 20px 22px; }
.txt { font-size: 14px; margin-top: 6px; color: var(--fg-body); }
.txt.warn { color: var(--fg-muted); font-size: 13px; margin-top: 4px; }
.progress { height: 2px; margin-top: -1px; overflow: hidden; border-radius: 2px; }
.progress i { display: block; height: 100%; width: 30%; background: var(--accent); animation: slide 1.6s var(--ease-out) infinite; }
@keyframes slide { from { transform: translateX(-100%); } to { transform: translateX(400%); } }
.list { margin-top: 20px; display: flex; flex-direction: column; gap: 10px; }
.vid { border: 1px solid var(--border); border-radius: var(--r-lg); overflow: hidden; background: var(--surface); transition: border-color var(--dur-2), box-shadow var(--dur-3); }
.vid.on { border-color: var(--border-strong); box-shadow: var(--shadow-1); }
.player { background: #000; }
.player video { width: 100%; max-height: 62vh; margin: 0 auto; }
.row-v { display: flex; align-items: center; gap: 8px; padding: 10px 12px 10px 16px; }
.name { display: flex; align-items: center; gap: 12px; flex: 1; min-width: 0; text-align: left; background: none; border: 0; padding: 4px 0; cursor: pointer; color: var(--fg); }
.name .grow { display: flex; flex-direction: column; }
.n { font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.sub { font-size: 12px; }
.foot { font-size: 12px; margin-top: 6px; }
@media (max-width: 640px) { .encode { flex-direction: column; align-items: stretch; } }
</style>

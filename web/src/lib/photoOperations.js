// 操作目标在打开确认框前冻结，后续切日期、刷新或切项目不能改变请求目标。
export function photoSnapshot(projectId, date, names) {
  return Object.freeze({ projectId, date, names: Object.freeze([...names]) })
}

export async function deletePhotos(snapshot, remove) {
  const result = { deleted: [], missing: [], failed: [], unattempted: [] }
  for (let i = 0; i < snapshot.names.length; i++) {
    const name = snapshot.names[i]
    try {
      await remove(snapshot.projectId, snapshot.date, name)
      result.deleted.push(name)
    } catch (error) {
      if (error.status === 404) result.missing.push(name)
      else {
        result.failed.push({ name, error })
        // 连接/会话失效后停止，不自动重放可能已经在服务端生效的删除。
        if (['network', 'timeout', 'auth'].includes(error.kind)) {
          result.unattempted = snapshot.names.slice(i + 1)
          break
        }
      }
    }
  }
  return result
}

export function deletionMessage(result) {
  const parts = [`已删除 ${result.deleted.length} 张`]
  if (result.missing.length) parts.push(`${result.missing.length} 张原本不存在`)
  if (result.failed.length) parts.push(`${result.failed.length} 张失败（${result.failed[0].error.message}）`)
  if (result.unattempted.length) parts.push(`${result.unattempted.length} 张未尝试`)
  return parts.join('，')
}

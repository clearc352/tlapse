// A bounded contact sheet; original files are only opened by the lightbox.
export function sampleFrames(length, limit = 9) {
  if (length <= 0 || limit <= 0) return []
  const count = Math.min(length, limit)
  if (count === 1) return [0]
  return Array.from({ length: count }, (_, i) => Math.round(i * (length - 1) / (count - 1)))
}

export function scrubIndex(start, offset, width, length) {
  if (length <= 0) return 0
  const step = Math.round(-offset / Math.max(1, width) * (length - 1))
  return Math.max(0, Math.min(length - 1, start + step))
}

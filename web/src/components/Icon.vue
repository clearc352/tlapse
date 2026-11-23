<script setup>
defineProps({ name: String, size: { type: [Number, String], default: 16 } })
const P = {
  camera: 'M4 8.5A2.5 2.5 0 0 1 6.5 6h1.3l1.2-1.8A1.5 1.5 0 0 1 10.2 3.5h3.6a1.5 1.5 0 0 1 1.2.7L16.2 6h1.3A2.5 2.5 0 0 1 20 8.5v8a2.5 2.5 0 0 1-2.5 2.5h-11A2.5 2.5 0 0 1 4 16.5zM12 16a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7z',
  pause: 'M8 5v14M16 5v14',
  play: 'M7 4.5v15l12-7.5z',
  edit: 'M4 20h4L19 9l-4-4L4 16zM13.5 6.5l4 4',
  trash: 'M4 7h16M9 7V4.5h6V7M6.5 7l1 12.5h9L17.5 7M10 11v5M14 11v5',
  download: 'M12 4v11M7 10.5l5 5 5-5M5 20h14',
  upload: 'M12 20V9M7 13.5l5-5 5 5M5 4h14',
  arrowLeft: 'M19 12H5M11 6l-6 6 6 6',
  chevronLeft: 'M15 5l-7 7 7 7',
  chevronRight: 'M9 5l7 7-7 7',
  close: 'M6 6l12 12M18 6L6 18',
  refresh: 'M20 11a8 8 0 1 0-2.3 5.7M20 5v6h-6',
  plus: 'M12 5v14M5 12h14',
  check: 'M5 12.5l4.5 4.5L19 7.5',
  bell: 'M6 16V11a6 6 0 1 1 12 0v5l1.5 2h-15zM10 20.5a2 2 0 0 0 4 0',
  bellOff: 'M6 16V11a6 6 0 0 1 9.5-4.9M18 11v5l1.5 2H9M10 20.5a2 2 0 0 0 4 0M4 4l16 16',
  film: 'M4 5h16v14H4zM8 5v14M16 5v14M4 9h4M4 15h4M16 9h4M16 15h4',
  image: 'M4 5h16v14H4zM4 16l5-5 4 4 2.5-2.5L20 17M15.5 9.5h.01',
  sliders: 'M4 7h9M17 7h3M4 17h3M11 17h9M15 5v4M9 15v4',
  terminal: 'M4 5h16v14H4zM7.5 9.5l3 2.5-3 2.5M13 15h4',
  grid: 'M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z',
  battery: 'M3 8h15v8H3zM21 10.5v3',
  bolt: 'M13 3L5 13.5h6L10.5 21 19 10h-6z',
  disk: 'M4 6h16v12H4zM7 14h.01M10 14h7',
  wifi: 'M2.5 9a14 14 0 0 1 19 0M5.5 12.5a9.5 9.5 0 0 1 13 0M9 16a4.5 4.5 0 0 1 6 0M12 19.5h.01',
  clock: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 7v5l3.5 2',
  more: 'M5 12h.01M12 12h.01M19 12h.01',
  logout: 'M15 4h4v16h-4M10 8l-4 4 4 4M6 12h10',
  select: 'M4 4h7v7H4zM13 13h7v7h-7zM14.5 6.5l2 2 3.5-4',
  moon: 'M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z',
  alert: 'M12 4l9 16H3zM12 10v4M12 17h.01',
  expand: 'M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5',
}
</script>
<template>
  <svg :width="size" :height="size" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path :d="P[name]" /></svg>
</template>

<script setup lang="ts">
withDefaults(defineProps<{ size?: number | string }>(), { size: 32 })
</script>
<template>
  <svg :width="size" :height="size" viewBox="0 0 64 64" aria-hidden="true" fill="none">
    <path d="M51.325 40.419 A22 22 0 1 1 39.419 11.675" stroke="currentColor" stroke-width="9" stroke-linecap="round" />
    <circle cx="31" cy="32" r="6.5" fill="currentColor" />
    <rect x="48.2" y="9.2" width="8.6" height="8.6" rx="2.4" transform="rotate(45 52.5 13.5)" fill="currentColor" />
  </svg>
</template>

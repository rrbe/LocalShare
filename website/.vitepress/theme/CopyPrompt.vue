<script setup lang="ts">
import { onBeforeUnmount, ref } from 'vue'

const props = defineProps<{
  text: string
}>()

const state = ref<'idle' | 'copied' | 'failed'>('idle')
let resetTimer: ReturnType<typeof setTimeout> | undefined

async function copy() {
  try {
    await navigator.clipboard.writeText(props.text)
    state.value = 'copied'
  } catch {
    state.value = 'failed'
  }

  if (resetTimer) {
    clearTimeout(resetTimer)
  }
  resetTimer = setTimeout(() => {
    state.value = 'idle'
  }, 2200)
}

onBeforeUnmount(() => {
  if (resetTimer) {
    clearTimeout(resetTimer)
  }
})
</script>

<template>
  <div class="copy-prompt">
    <p class="copy-prompt__text">{{ text }}</p>
    <button type="button" class="copy-prompt__button" @click="copy">
      {{ state === 'copied' ? '已复制' : state === 'failed' ? '复制失败，请手动选择' : '复制给 Codex' }}
    </button>
    <span class="sr-only" aria-live="polite">
      {{ state === 'copied' ? '部署提示已复制' : state === 'failed' ? '复制失败' : '' }}
    </span>
  </div>
</template>

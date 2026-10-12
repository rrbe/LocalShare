<script setup lang="ts">
import { ref } from 'vue'

defineProps<{
  src: string
  alt: string
  compact?: boolean
}>()

const dialog = ref<HTMLDialogElement | null>(null)

function open() {
  dialog.value?.showModal()
}

function close() {
  dialog.value?.close()
}

function closeOnBackdrop(event: MouseEvent) {
  if (event.target === dialog.value) {
    close()
  }
}
</script>

<template>
  <button
    type="button"
    class="zoom-trigger"
    :class="{ 'zoom-trigger--compact': compact }"
    :aria-label="`${alt}，点击放大`"
    @click="open"
  >
    <img class="doc-screenshot" :src="src" :alt="alt">
  </button>

  <dialog ref="dialog" class="image-zoom" @click="closeOnBackdrop">
    <div class="image-zoom__panel">
      <button type="button" class="image-zoom__close" aria-label="关闭大图" @click="close">
        ×
      </button>
      <img :src="src" :alt="alt">
    </div>
  </dialog>
</template>

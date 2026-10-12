import DefaultTheme from 'vitepress/theme'
import CopyPrompt from './CopyPrompt.vue'
import ZoomImage from './ZoomImage.vue'
import './custom.css'

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component('CopyPrompt', CopyPrompt)
    app.component('ZoomImage', ZoomImage)
  },
}

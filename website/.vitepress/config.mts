import { defineConfig } from 'vitepress'

const pagesBase = process.env.DOCS_BASE

export default defineConfig({
  base: pagesBase ? `${pagesBase}/` : '/',
  lang: 'zh-CN',
  title: 'LocalShare 文档',
  description: 'LocalShare Client 与 Server 的使用和部署文档',
  cleanUrls: true,
  head: [
    ['meta', { name: 'theme-color', content: '#efeae1' }],
  ],
  themeConfig: {
    siteTitle: 'LocalShare 文档',
    nav: [
      { text: '文档', link: '/' },
      { text: '下载', link: 'https://github.com/rrbe/LocalShare/releases' },
    ],
    sidebar: [
      {
        text: '开始',
        items: [
          { text: '概览', link: '/' },
          { text: '快速开始', link: '/client/getting-started' },
        ],
      },
      {
        text: 'LocalShare Client',
        items: [
          { text: '传递文件', link: '/client/file-sharing' },
          { text: '传递文本', link: '/client/text-transfer' },
        ],
      },
      {
        text: 'LocalShare Server',
        items: [
          { text: 'Server 简介', link: '/server/' },
          { text: '安装与部署', link: '/server/deployment' },
          { text: '让 Codex 部署', link: '/server/codex-deploy' },
          { text: '连接 Client', link: '/server/connect-client' },
        ],
      },
    ],
    search: {
      provider: 'local',
      options: {
        translations: {
          button: {
            buttonText: '搜索文档',
            buttonAriaLabel: '搜索文档',
          },
          modal: {
            noResultsText: '没有找到相关内容',
            resetButtonTitle: '清除查询条件',
            footer: {
              selectText: '选择',
              navigateText: '切换',
              closeText: '关闭',
            },
          },
        },
      },
    },
    outline: false,
    socialLinks: [
      { icon: 'github', link: 'https://github.com/rrbe/LocalShare' },
    ],
    docFooter: {
      prev: '上一页',
      next: '下一页',
    },
    footer: {
      message: 'LocalShare 基于 MIT License 发布',
    },
  },
})

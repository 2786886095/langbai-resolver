# langbai解析设计 QA

最终状态：通过。

## 验收范围

- 参考图：`design-reference/langbai-dark.png`、`design-reference/langbai-light.png`
- 实现截图：`design-reference/implementation-dark-updater.png`、`design-reference/implementation-light.png`
- 对照图：`design-reference/design-qa-dark.png`、`design-reference/design-qa-light.png`
- 视口：1440 × 900

## 结果

- P0：0
- P1：0
- P2：0
- 深浅色的信息层级、留白、卡片边界、蓝色主操作、侧栏导航与产品形象保持一致。
- 实现保留真实空任务状态，未复制参考图中的演示下载数据；有任务后由实际下载记录填充。
- 桌面端采用侧边栏，窄屏切换到底部导航；Flutter 组件测试覆盖 390 × 844 窄屏无布局异常。
- 设置页包含主题、默认保存路径、启动自动检查更新和手动检查入口。
- 剪贴板链接在启动或回到前台时直接路由到对应解析页，首页不再保留检查按钮、确认卡片或功能开关。

## 说明

参考图中的窗口控制按钮属于静态视觉示意。Web、Android 和 iOS 使用平台自身窗口/系统导航；Windows 原生窗口由 Flutter Runner 提供，未在内容区域重复绘制伪窗口控件。

# 电视设置页面结构

2026-10-25。入口仍为远程画面上的设置按钮。

## 信息组织

| 官方 Tab | 内容 |
| --- | --- |
| 画面 | 显示器、回传分辨率、画面比例 |
| 画质 | 码率策略、帧率；展开高级选项后显示编码和连接统计 |
| 声音 | 每台电脑的电视播放增益、恢复原始音量 |
| 遥控器 | 设备绑定、按键选择、单击/双击/长按动作；只在选中语音键时显示检测 |
| 界面 | 角落位置、横纵排列、当前控件的文字布局预览 |

每个 Tab 独立滚动；顶部分类与完成按钮保持可见。切换分类会取消尚未完成的遥控器/语音键学习，设置关闭继续沿用既有输入所有权清理。界面重整不修改保存键名、默认分辨率、帧率、码率策略或实际悬浮控件坐标。

## 源码分层

- **Token**：`tv/overlay/entry/src/main/ets/theme/TvSettingsTokens.ets` 管理设置字号、颜色、间距与尺寸；`TvControlLayoutPreviewTokens.ets` 只管理布局预览的专属尺寸。
- **组件**：`components/TvSettingsSection.ets` 提供分区布局，`TvSettingsPane.ets` 提供单页滚动容器；`TvControlLayoutPreview.ets` 只展示预览，不持有业务状态、不接管输入。预览几何位于 `services/TvControlLayoutPreviewGeometry.ets`，可独立测试。
- **页面编排**：`tv/fragments/settings-panel.ets` 使用官方 Tabs/TabContent、Select、Slider、Button；`remote-key-settings.ets` 和 `layout-settings.ets` 分别编排遥控器与布局设置。不重新实现原生选择器、滚动器和焦点系统。
- **行为**：`display-members.ets`、`remote-key-members.ets`、`corner-controls.ets` 保留会话、偏好、设备绑定与实际控件行为；状态机继续位于独立服务。
- **集成**：`scripts/prepare_client.py` 从上述源文件生成固定上游工程。`.work/client` 不是源码入口。

## 验证边界

签名 HAP 已构建、替换安装并启动。84 项前端回归通过，包含实际映射状态机、输入所有权、画布生命周期、首页导航及预览几何。独立代码审查核对了选项索引、状态更新、Tab 切换取消学习和已有设置保留。

尚未完成新版设置所有分页的电视视觉与遥控器操作验收。菜单键已在实机日志中确认到达页面层，其独立绑定和页面补接已安装；实体四方向键为何变成 PAN、语音键是否能交给普通应用仍在定位，不因设置整理而改变结论。

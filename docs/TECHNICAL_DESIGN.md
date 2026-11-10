# 我的时区：技术栈与架构

## 目标和当前范围

目标是可添加到 Mac 桌面和通知中心的原生时钟小组件。真实时间独立于手动修改的系统时间；个人时区在真实时间上增加提前量。最终设计支持单/双时钟、指针/数字、瓷白/石墨黑以及 12/24 小时制。

1.1.0 当前实现：中号组件对照真实时间和系统时间，配套 App 提供后台校准、统一小时制、登录启动与按需硬件状态。个人偏移、完整外观和指针动画属于后续产品开发。

## 数据流

```mermaid
flowchart LR
    N[公开 NTP 时间源] --> C[ClockCore 校准与连续计时]
    C --> A[SwiftUI 配套 App]
    P[UserDefaults 小时制] --> A
    C --> L[仅回环快照服务]
    P --> L
    L --> W[WidgetKit 时间线]
    W --> D[动态计时文本]
```

```text
真实 UTC = 上次校准 UTC + 连续时钟经过时长
系统偏差 = 系统 UTC - 真实 UTC
```

## 实际技术栈

| 技术 | 职责 |
|---|---|
| Swift 6、Swift Package Manager | 原生实现、共享核心、命令行核对和检查 |
| SwiftUI、AppKit | App 界面、休眠和唤醒事件 |
| WidgetKit | 原生组件、系统渲染和预计算时间线 |
| Foundation | 日历、时区、编码和固定格式静态时间 |
| Darwin UDP socket | SNTP 请求、超时与响应来源过滤 |
| `mach_continuous_time` | 包含休眠时长的连续计时 |
| Network、URLSession | 当前版本 App 与组件之间的本机快照传输 |
| UserDefaults、AppStorage | 一个全局的持久化小时制设置 |
| ServiceManagement | 使用 SMAppService.mainApp 注册/取消系统登录启动，读取真实状态 |
| Darwin 资源计数器 | 读取整机 CPU、进程 CPU/物理内存；sysctl 获取基础硬件信息 |
| Swift Testing | 协议、时间、格式与边界回归检查 |
| ImageRenderer、Vision | 无窗口渲染生产文本，识别数字并与参考值比较 |
| Xcode、swiftc、codesign、hdiutil | 构建、代码签名完整性检查和 DMG 打包 |

没有数据库、云后端、大模型调用或第三方运行依赖。

## 校时核心

客户端查询公开 NTP 服务，检查长度、版本、模式、同步状态、层级、请求标记、服务器时间戳和网络延迟；时间戳解码覆盖 2036 年后的 NTP era。

成功校准后，单调时钟推进真实 UTC。系统日期只用于比较偏差和生成组件显示锚点。网络失败时保留已有锚点并显示 `offlineHoldover`；没有有效锚点时显示 `unsynchronized`。估计的不确定度随样本年龄增加，不视为严格误差上界。

## 动态显示与小时制

早期用固定 GMT 显示时区表达校正值，实际 SwiftUI 动态文本受环境时区影响，而且不能可靠保留秒级精度。0.3 改为校准计时锚点：

```text
计时起点 = 系统采样时间 - 需要显示的本地时分秒所代表的秒数
```

0.4 两列都使用系统内置持续时间数据源，避免一列跟随地区设置而另一列固定为 24 小时制。

- 24 小时制：00–23。
- 12 小时制：01–12，分别标明 AM/PM。
- 两列可能处在不同半天，例如真实时间 11:55 AM、系统时间 12:05 PM，因此分别计算显示值和标签。
- 在两列较早的小时边界更新锚点，处理 12:59 → 01:00、午夜、正午和夏令时变化；预生成约一天的时间线。
- App 的设置保存后，请求小组件读取携带该设置的新快照。

## 当前版本的数据共享

尚未使用 App Groups。配套 App 仅监听 `127.0.0.1:45931`，组件请求本地快照；服务不监听局域网。因此当前版本需要 App 保持运行。

后续可在签名和容器配置齐备后评估 App Groups。共享数据不意味着组件持续运行，WidgetKit 仍由系统调度刷新。

## 后台生命周期

0.5 使用 `LSUIElement` 与 AppKit 的 accessory 激活策略隐藏 Dock 图标。AppKit delegate 持有长期运行的校时模型，首次启动不创建设置窗口；Finder/Spotlight 的 reopen 事件才显示 SwiftUI 设置界面。关闭窗口只收起，显式退出才停止进程。

系统改时、时区变化和唤醒通知触发刷新请求，并保留一秒的轻量改时检测兜底。只有窗口可见时才逐秒发布 UI 快照；取消逐秒诊断日志。当前版本关闭窗口时移除 HostingController、内容视图和窗口引用，释放设置界面。

登录开关只有用户操作时才调用 SMAppService；以系统 status 为准，区分 enabled、requiresApproval、notRegistered 和 notFound。失败后恢复实际状态，并提供明确错误。登录时沿用无窗口启动路径，窗口禁止自动恢复。代理检查不会修改用户真实登录项。

后台状态下 WidgetKit 请求是否及时执行，仍须实际验收；详见 [性能记录](PERFORMANCE.md)。

## 硬件面板的成本边界

硬件面板位于设置页，组件进程不包含这部分代码。整机 CPU 由主机 tick 的差值计算；App CPU 使用进程累计 CPU 时间差，按单核 100% 计；App 内存使用 task_info 的 phys_footprint，除以总内存得到占比。

采样器没有独立线程、定时器或历史数组，复用既有监测循环，只有页面可见且间隔达到两秒时采样。隐藏时释放 reader；关闭时进一步释放整个设置界面。基础机型、芯片和内存数据一次性缓存，不读取序列号。

用户已接受少量首次使用开销。隔离压力测显示首用约 0.5–0.6 MiB、单次读取约 2.3 微秒，10 万至 100 万次之间内存没有继续增长。它只覆盖采样器，不代表完整 SwiftUI 窗口或 ServiceManagement 的增量；对象释放也不保证操作系统立即收回所有物理页。

## 核对状态和边界

已观察到真实系统调快后的数字显示正确。22 项自动化检查覆盖时钟、小时制、中文状态、登录状态与错误恢复、CPU 计数器及采样生命周期。离屏 SwiftUI 渲染用于检查生产显示代码，不代替原生宿主验收；系统原生控件也无法由 ImageRenderer 完整绘制。

系统调回、实际休眠、实际断网和登录启动仍需在使用环境中复核。`reloadAllTimelines` 是请求，不保证立即重绘；系统刚改时或主 App 退出时，组件可能暂时沿用旧锚点。发布版本号不代表这些环境场景已全部完成实机检查。

## 参考资料

- [Apple：小组件刷新机制](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [Apple：TimeDataSource](https://developer.apple.com/documentation/swiftui/timedatasource)
- [Apple：创建 Widget 扩展](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension)
- [NIST：Internet Time Service](https://www.nist.gov/pml/time-and-frequency-division/time-distribution/internet-time-service-its)
- [Apple：LSUIElement 后台代理应用](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)
- [Apple：处理再次打开应用](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen%28_%3Ahasvisiblewindows%3A%29)
- [Apple：SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)

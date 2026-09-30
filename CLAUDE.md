# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

「高铁笔记」(TravelNotes):个人自用 iOS App,每张车票渲染成一张手绘风车票,票下挂日记与照片。SwiftUI + SwiftData,iOS 17+,无第三方依赖、无后端、数据全存手机本地。UI 文案、注释均为中文——新代码保持中文。

产品/视觉设计与统计口径见 `DESIGN.md`,功能清单与真机运行说明见 `README.md`。

## 构建与运行

```bash
# Xcode 打开运行(⌘R)
open TravelNotes.xcodeproj

# 命令行构建(模拟器)
xcodebuild -project TravelNotes.xcodeproj -scheme TravelNotes \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build

# Mac Catalyst(Xcode 里目的地选「My Mac (Mac Catalyst)」⌘R 即可):
# Mac 本地构建没有 7 天签名限制,适合常驻查行程/记日记;数据与手机各自独立。
# 注意:免费团队签不出 App Sandbox(Catalyst 分发才强制沙盒),Mac 版未沙盒运行,
# 数据固定在 ~/Library/Application Support/TravelNotes/(TravelNotes.store + Photos/),
# 备份 = 拷走该目录;不要让数据落回共享的 default.store 或用户 ~/Documents(AppData.swift 已约束)
xcodebuild -project TravelNotes.xcodeproj -scheme TravelNotes \
  -destination 'platform=macOS,variant=Mac Catalyst' build

# 一键构建 + 安装到 /Applications(Spotlight/Launchpad 可搜,同 bundle id 覆盖安装不丢数据)
scripts/install_mac.sh
```

- 工程由 `project.yml` + XcodeGen 生成。**增删文件也要**先执行 `~/development/bin/xcodegen generate`(pbxproj 是显式文件引用;xcodegen 装在 `~/development/bin`,不在 PATH);增删 target/构建设置同样要重新生成。
- 没有测试 target。验证靠真机/模拟器手跑 + 下述启动参数。
- 模拟器 runtime:iOS 27(如未装则 `xcodebuild -downloadPlatform iOS`)。

### 调试启动参数(全部在 `TravelNotesApp.swift` / `MailSyncEngine` / `SnapshotSupport` 里分发)

| 参数 | 作用 |
|---|---|
| `-UITestSeed` | 注入演示数据(`Models/SampleData.swift`) |
| `-BoardTab` / `-TripTab` / `-StatsTab` / `-FootprintTab` / `-SyncTab` | 启动直达对应 Tab(顺序:大屏/票根/行程/统计,足迹和同步在 More 里) |
| `-MailUser x -MailPass y [-MailOwner 名字]` | 预置邮箱账号并触发同步;开启 trace 到沙盒临时目录 `tn_trace.log` |
| `-MailSyncTest [-MailHost/-MailPort/-MailSince...]` | 同步链路自检,结果写 `tn_sync.txt`(`/tmp` 与沙盒临时目录都落一份)后退出(可指向 `scripts/mock_imap.py` 本地 mock;注意模拟器 iOS 17+ 是虚拟机,127.0.0.1 连不到 Mac,要传 Mac 局域网 IP + `-MailPort 8025`,8025 端口自动明文) |
| `-HomeTab` | 启动直达票根页(其余 Tab 参数见上) |
| `-AddSheet` | 配合 `-HomeTab` 使用:启动即弹新增票根页,方便无头截图 |
| `-BoardRoute 车次号` | 配合 `-BoardTab`:加载完自动推入该车经停时刻表详情,方便无头截图 |
| `-Snapshots` / `-MapSnapshot` | 把票面/足迹地图渲染成 PNG 存盘,用于视觉核对 |

## 架构

### 数据层(SwiftData)

两个 `@Model`:`TicketEntry`(正式票根,含日记、照片文件名数组、票面皮肤)与 `MailCandidate`(邮件解析出的待确认票根,用户在同步页确认后才转正)。`Shared/Theme.swift` 的 `TicketInfo` 是与存储解耦的票面数据快照——所有票面渲染(含表单实时预览)只吃 `TicketInfo`,不直接摸 `@Model`。

### 邮件同步管线(核心,跨多个 Services 文件)

```
IMAPClient (裸 IMAP over Network.framework)
  → MIME.swift 解码(折叠头/base64/QP/UTF-8/GBK,剥 HTML)
  → TicketMailParser 解析 12306 邮件 → [ParsedTicket]
  → MailSyncEngine 四阶段过滤 → 写入 MailCandidate
  → SyncView 用户确认 → TicketEntry
```

`MailSyncEngine.sync()` 的四阶段规则是本仓库最容易改坏的地方,改动前先读懂:

1. **全文件夹扫描**:LIST 扫**全部**邮件文件夹(老邮件可能被归档,文件夹名不一定含 12306);首次/全量 `since 2010`,日常增量按上次同步时间。全量不依赖 `UID SEARCH`(QQ 对老邮件搜不准),改按 `UID FETCH 1:*` 拉头部自筛发件人/主题。
2. **退票**:主题含「退票/退单」的邮件解析出的 tripKey 进拒绝集。
3. **改签**:按订单号分组,同订单只保留**最后一封**改签邮件里的新票;改签前的原票(同订单其他邮件)作废。去重键 = `tripKey(车次+区间+日期)`,跨邮件/跨批次全局去重(`MailCandidate.messageId` 存的其实是 `"mid-\(tripKey)"`,字段名是历史遗留,别当真实 Message-ID 用)。
4. **建候选**:非退票、非作废、tripKey 未见过 → `MailCandidate`。

QQ 邮箱要求登录前发 `ID (...)` 命令(`IMAPClient`/`MailSyncEngine` 里已处理,勿删)。自动同步 = 回前台时触发,**每天最多一次**。邮箱授权码存 Keychain(带 fallback key),不上传。

解析侧易踩的坑(`TicketMailParser`/`MIME`):Date 头要兼容 QQ 的 `(CST)` 注释、无星期、`+0800` 偏移;2015 年前老邮件只写「04月29日」时按**发件时间**推年份(取与发件日最近的年,别推到未来);「一」可作站名分隔符(仅老邮件兜底)。

### 其他横向件

- `Services/TrainLiveService.swift`:12306 小程序「车次运行信息」接口(免登录,UA 伪装 MicroMessenger)→ 检票口/出站口/晚点;`platform()` 查车站大屏取站台(提前几天就有);`estimatedGate()` 出发当天检票口未公布时推导「预计检票口」——先用同车当日实测(同车固定站台固定口),同站台邻车只兜底。缓存:实时值 300 秒;**已查到的检票口(正式+预计)缓存到当天结束**,接口偶尔回 `--` 也不丢。`bigScreen()` 拉全站当日大屏(「大屏」页签用);车次运行信息里 `ticketStatus` 实测 1=候车 2=正在检票 3=已发车(无独立「停止检票」码);大屏接口偶发缺始发车(上游数据抖动),靠 300 秒缓存后自然恢复。
- `Services/TrainScheduleService.swift`:12306 公开接口 → 站名电报码、车次内部编号、经停时刻表(供详情页到达时刻/日历用);按「车次+日期」缓存,历史日期查不到时按当前运行图兜底。
- `Services/TripCalendar.swift`:EventKit 写系统日历 / 导出 `.ics`(详情页右上角 ➕),到达时刻查经停时刻表,出发前 2 小时提醒。
- `Services/TripNotifications.swift`:行程本地通知——开车前 2 小时 / 预计开始检票(开车前 20 分钟)/ 即将停止检票(开车前 5 分钟);只排未来 24 小时内的行程,回前台全量重排(标识符 `trip-notify-*`),系统 64 条上限内;检票时刻 12306 不提前公布,按经验窗口预估。
- `Views/TicketViews.swift`:红/蓝两套票面,纯 SwiftUI 矢量(无图片素材),微缩卡与全尺寸共用;装饰性票号由乘车日期确定性推导(`TicketInfo.serialText`)。
- `Views/FootprintView.swift`:MapKit 强制深色 + 发光弧线(`RouteGeometry` 画大圆弧)。
- `Services/Stations.swift` + `Resources/Stations.json`(~190 站):站名补全、坐标、里程估算(直线距离 × 1.25,同城多站合并;任一端缺坐标则里程不计)。
- `Services/PhotoStore.swift`:照片存 `Documents/Photos/<UUID>.jpg`,入沙盒时压到最长边 1600px / JPEG 0.8;删除行程须同步删文件。
- 备份 = 拷贝 App 沙盒 `Documents/`(sqlite + Photos)。

## 约定

- 不引入 CocoaPods/SPM 第三方依赖——「拉下来就能编译」是硬约束。
- UI 交互改完用 `-Snapshots`/`-MapSnapshot` 出图核对票面与地图,别只靠编译通过。
- `scripts/mock_imap.py` 是本地 mock IMAP 服务器,改邮件解析逻辑时用它 + `-MailSyncTest` 做端到端验证。

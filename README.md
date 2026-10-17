# StudyHub TV

装在电视上看片的 App：把 NAS 里的**图片 / 视频 / 音乐**直接放到电视上，用遥控器浏览。
和 [StudyHub](https://github.com/yinchenglu/studyhub)（手机学习 App）同一个作者、同一套构建体系，但功能完全独立：**只做媒体播放，不做学习**。

一句话：你 NAS 里的文件夹长什么样，电视上就长什么样。**没有刮削、没有强制整理**，
不需要 Plex/Jellyfin 那种"先把媒体库扫描命名一遍"的前置工作。

![界面](https://img.shields.io/badge/界面-Kodi%20风格单页-blue) ![协议](https://img.shields.io/badge/协议-WebDAV%20%2B%20SMB-green) ![框架](https://img.shields.io/badge/框架-Flutter-orange)

---

## 功能

- **一个界面**：左侧主菜单（账户 / 图片 / 视频 / 音频 / 工具 / 设置），右侧内容区， Kodi 那种布局
- **双协议登录**，可保存多个账号、随时切换：
  - **WebDAV**：群晖、威联通、Alist、Nextcloud、chfs 等
  - **SMB**：Windows 共享文件夹、NAS 的 Samba 共享（SMB 1.0 / 2.0 / 2.1）
- **目录约定自动识别**（v1.2）：连上账号后会自己找 `StudyHub-TV` 文件夹，
  下面的 `image` / `video` / `audio` / `download` 分别对应图片、视频、音频和「软件下载」，
  不用在账号里手填路径（`images`、`photo`、`图片` 这类写法也都认）
- **手机扫码填账号**（v1.2）：「账户 → 手机扫码填写」，电视上出现二维码，
  手机扫开就是一个表单，填完点保存，电视直接落库并连接 —— 不用遥控器打密码
- **缩略图**：
  - 图片 → 原图按卡片大小解码，磁盘缓存
  - 视频 → 原生抽帧（第 1 秒）+ 磁盘缓存，第二次进目录秒开
- **播放**：libmpv 内核（mkv / avi / ts / rmvb 等常见格式都能吃），支持拖进度条、±10 秒
- **播放面板**（v1.2，播放中按菜单键）：目录列表、倍速（0.5×–3×）、
  播放模式（顺序 / 单个循环 / 随机 / 目录循环）、跳过片头、跳过片尾（长按 OK 重置）
- **工具**（v1.3 重新划分）：
  - **软件下载**：浏览服务器 `download` 子文件夹，按 OK 把文件存到电视本地
  - **文件管理**：看本地下载好的文件、删掉腾空间、点 APK 直接装（走 FileProvider）
  - **应用管理**：列出电视上装的应用（图标 / 包名 / 系统应用标记），可打开、看详情、卸载
  - **内存清理**：显示整机内存占用，一键清本应用缓存（缩略图 + 临时文件）
  - **自启动管理**：按品牌跳到系统的自启动开关页（安卓没有统一 API，只能跳转）
- **遥控器 + 触屏**双支持：方向键 / OK / 返回全部适配，也能用鼠标、触屏操作
- **手机 / 平板自适应**（v1.4）：窗口宽度小于 720dp 时自动切成
  **底部导航 + 满宽内容**（不再固定 246dp 侧栏），标题栏、播放控制条、
  二维码页、账号表单都按窄屏重排，字号和留白同步收窄

## 遥控器键位

| 按键 | 主界面 | 播放中 |
| --- | --- | --- |
| 方向键 | 移动光标 | ←→ 快退/快进 10 秒，↑↓ 音量 |
| OK / 确定 | 打开 | 暂停 / 继续（面板里是执行，「跳过片头/片尾」行**长按 = 重置**） |
| 返回 | 回上一级目录 → 回菜单 | 先关面板，再退播放 |
| 菜单键 | 刷新当前目录 | 打开播放面板（目录列表 / 倍速 / 播放模式 / 跳片头片尾） |

手机上没有遥控器，全部改成点按：底部导航切分区，点网格进目录/播放，
播放页底部条是两行（时间+设置 / 播放控制），「跳过片头/片尾」长按即重置。

工具里的几个页面各有自己的菜单键用法：**文件管理**菜单键 = 删除选中项，
**应用管理**菜单键 = 卸载选中应用（系统应用不给卸）。

连接测试、清缩略图缓存、诊断信息挪到了「设置」的最下面 —— 那几项一辈子用一两次，
不占工具的位置。

## 安装

到 [Releases](https://github.com/yinchenglu/StudyHub-TV/releases) 下载对应 APK：

- 2016 年后的盒子 / 新电视 → `StudyHub-TV-arm64.apk`
- 老盒子（含安卓 5.0 那一代）→ `StudyHub-TV-armv7.apk`

拿不准就**先装 armv7**：它是 32 位包，绝大多数老电视都是这个架构。

用 U 盘拷过去安装，或通过电视上已有的文件管理器打开。

**系统要求：Android 5.0（API 21）及以上。**

从 v1.1.0 起专门为安卓 5.0 做了两处调整：

- CI 的 Flutter 钉在 **3.32.8**（最后一批 `minSdkVersion = 21` 的版本）。Flutter 3.35 起官方把
  最低 API 抬到 24，用它打出来的包装到安卓 5/6 的电视上会直接提示"应用未安装"。
- `compileSdk` 单独抬到 36（media_kit 原生库的要求），和 `minSdk 21` 不冲突。

> 装的时候若提示"解析包错误"，八成是下错了架构：安卓 5.0 的盒子几乎都是 32 位，装 armv7。

## 快速上手

1. 在服务器上按这个结构放文件（名字大小写不敏感，`images`/`photo`/`图片` 也认）：

   ```
   StudyHub-TV/
     ├── image/       ← 「图片」
     ├── video/       ← 「视频」
     ├── audio/       ← 「音频」
     └── download/    ← 「工具 → 软件下载」
   ```

2. 首次启动 → 左菜单「账户」→「添加账号」（或者点「手机扫码填写」，用手机填更快）
3. 选协议，填地址：
   - **WebDAV**：`http://192.168.1.10:5005`（群晖示例）+ 子目录（可空）+ 账号密码
   - **SMB**：`192.168.1.10` + 共享目录 `/media` + 账号密码
4. 「测试并保存」—— 通了就直接进图片分区
5. 左菜单切「视频」，选片，OK 播放；播放中按菜单键有倍速、播放模式、跳片头片尾

> 没建 `StudyHub-TV` 也不用慌：App 会退回按账号根目录浏览，只是不自动分拣类型。

## 技术方案（为什么这么做）

- **Flutter**：和 StudyHub 同框架，UI 一套代码；CI 锁 Flutter 3.32.8（为兼容安卓 5.0，见上文）
- **播放内核 media_kit（libmpv）**：电视上格式五花八门，系统播放器经常缺解码器
- **WebDAV 手写客户端**：中文路径编码、`Depth:1` 降级、Range 探测这三件事现成库都做不好（与 StudyHub 同源）
- **SMB 用纯 Dart 的 smb_connect**：
  - 不引原生库 → CI 不会碰 NDK 的坑
  - 播放走**应用内 127.0.0.1 中转服务**（`SmbBridge`）：把「按字节范围读 SMB」翻译成标准 HTTP Range，
    播放器、抽帧、图片加载全都按 http 处理，不用为 SMB 单独适配三套
  - 协议上限 SMB 2.1：服务器如果强制只允许 SMB3，去服务器把最低协议改成 SMB2（群晖：控制面板 → 文件服务 → SMB → 高级设置）
- **视频缩略图走原生 MethodChannel**：`MediaMetadataRetriever` 支持"http 地址 + 请求头"直接抽帧，
  不用把整集视频下载下来；三层缓存（原生抽取 → 磁盘 → 并发去重）保证列表不卡

## 构建

### GitHub Actions（推荐，零环境）

push 到 main 自动构建；推 `v*` 标签会自动发 Release：

```bash
git tag v1.0.1
git push origin v1.0.1
```

产物在 Actions 页面的 Artifacts（或 Release 页）。

### 本地构建

```bash
flutter pub get
flutter build apk --release --split-per-abi
```

注意：仓库里没有 `android/` 目录，本地构建前要先跑一遍 CI 的注入逻辑
（见 `.github/workflows/build-apk.yml` 的「生成 Android 骨架并注入自定义内容」一步），
或者直接 `flutter create --platforms=android --org com.yinchenglu --project-name studyhub_tv /tmp/skel`
然后把清单、图标、MainActivity 按同样方式拷进去。

### 固定签名（避免每次升级都要卸载重装）

在仓库 Secrets 里配四个值，CI 自动签名（缺省退回 debug 签名，那种包不能覆盖安装）：

```bash
keytool -genkeypair -v -keystore upload-keystore.jks -alias studyhubtv \
  -keyalg RSA -keysize 2048 -validity 36500
base64 -w0 upload-keystore.jks   # 结果放进 SIGNING_KEYSTORE_BASE64
```

| Secret | 内容 |
| --- | --- |
| `SIGNING_KEYSTORE_BASE64` | 上面 base64 的输出 |
| `SIGNING_STORE_PASSWORD` | keystore 密码 |
| `SIGNING_KEY_ALIAS` | `studyhubtv` |
| `SIGNING_KEY_PASSWORD` | key 密码（一般和 keystore 一样） |

`tools/gen_icons.py` 可重新生成图标和电视横幅（改配色只需改脚本里的常量）。

## 常见问题

| 现象 | 原因 / 解法 |
| --- | --- |
| WebDAV 报 401 | 用户名错，或需要用"应用密码"而不是登录密码（Nextcloud） |
| WebDAV 报 405 | 服务器没开 WebDAV 服务，或地址填成了普通网页端口 |
| SMB 连不上 | 端口 445 被路由器挡了 / 服务器只允许 SMB3 → 改最低协议为 SMB2，或改用 WebDAV |
| SMB 登录失败 | Windows 共享要用"电脑上登录用的微软账号"，不是 PIN |
| 视频不能拖进度条 | 服务器不支持 Range 请求（设置 → 连接测试 会提示）；能播放，只是不能拖 |
| 封面一直是灰色图标 | 老容器（rmvb 等）抽帧失败，属正常降级；播放不受影响 |
| 电视桌面上看不到 App | 部分电视只显示 LEANBACK_LAUNCHER 应用 —— 本 App 已声明，若还看不到检查是否装到了"用户分区" |
| 安装时报"解析包错误" | 下错架构了：安卓 5/6 的盒子基本都是 32 位，装 `armv7` |
| 安卓 5.0 上 HTTPS 的 WebDAV 连不上 | 安卓 5 的证书库很老（不含 Let's Encrypt 新根证书）。NAS 上改用 `http://` 地址，或把盒子系统升级 |
| 安卓 5.0 上视频发绿 / 花屏 | 老 GPU 硬解兼容性问题。先用「设置 → 连接测试」确认能拉到数据，再换片源试；`mpv` 软解会自动接管 |

## 版本规划

- **V1（1.0–1.1）**：单界面浏览 + WebDAV/SMB + 缩略图 + 播放 + 多账号 + 安卓 5.0 支持
- **V1.2**：目录约定自动识别、播放面板（目录列表 / 倍速 / 播放模式 / 跳片头片尾）、
  手机扫码填账号、下载工作、账户内嵌表单
- **V1.3**：工具重新划成 软件下载 / 文件管理 / 应用管理 / 内存清理 / 自启动管理，
  连接测试与诊断信息挪进设置
- **V1.4（当前）**：手机适配 —— 窄屏换底部导航、内容满宽，标题栏 / 播放控制条 /
  扫码页 / 账号表单全部按窄屏重排；不再强制横屏
- **V2**：SMB3 / 字幕加载（srt/ass，含外挂字幕自动匹配）、音频封面（ID3）、OK 键图片放大、断线自动重连
- **V3**：播放进度记忆 + 继续观看、收藏夹、手机端（StudyHub）推送"在电视上打开"

## 目录结构

```
lib/
  main.dart / app.dart          入口与根组件
  core/                          常量（含目录约定）、主题、格式化、按键判定
  data/
    models.dart                  账号 / 条目 / 分区 / 播放模式模型
    store.dart                   本地存储（账号 + 密码加密 + 设置）
    thumb_cache.dart             视频缩略图三层缓存
    pair_server.dart             手机扫码填账号的局域网表单服务
    downloader.dart              「软件下载」的落盘实现
    remote/
      remote_source.dart         统一文件源接口
      webdav_source.dart         WebDAV 实现
      smb_source.dart            SMB 实现
      bridge_server.dart         SMB → HTTP 本地中转（Range 支持）
  native/
    thumb_channel.dart           原生抽帧通道封装
    system_channel.dart          原生系统能力（应用列表 / 内存 / 打开文件 / 自启动）
  state/app_state.dart           全局状态（含 StudyHub-TV 目录自动识别）
  ui/                            界面（shell 是唯一主界面）
    account_panel.dart           账户：切换 / 内嵌表单 / 扫码
    account_edit_form.dart       账号表单本体
    pair_page.dart               二维码页
    player_page.dart             播放器 + 播放面板 + 目录列表
    download_page.dart           工具 → 软件下载
    file_manager_page.dart       工具 → 文件管理（本地文件、装 APK、删除）
    app_manager_page.dart        工具 → 应用管理
    memory_page.dart             工具 → 内存清理
    autostart_page.dart          工具 → 自启动管理
    compact_nav.dart             窄屏（手机）底部导航条
android_custom/                  CI 注入的清单、图标、原生代码（含 FileProvider 配置）
.github/workflows/build-apk.yml  云端构建
tools/gen_icons.py               图标生成
```

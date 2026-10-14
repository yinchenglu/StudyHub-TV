# StudyHub-TV

一个跑在安卓电视 / 电视盒子上的**局域网媒体库浏览器**，界面类似 Kodi：
左边是「图片 / 视频 / 音频 / 电影 / 电视剧 / 全部文件」，右边直接显示里面的内容，
用遥控器或者手指（触屏）就能浏览和播放。

- **最低支持 Android 5.0**（API 21），一直到最新的安卓版本
- 支持 **SMB** 和 **WebDAV** 两种连接方式
- **多个账号同时保存，一键切换**
- 自动识别服务器上的**固定文件夹**（图片 / 视频 / 音频 / 电影 / 电视剧）
- 能播放**图片、视频、音频**，视频/音频自动抽取**预览图**
- 播放界面参考影视仓 / TVbox：全屏 + 底部控制条

> 本版（V1）**不含影视刮削（海报墙）**，按需求已裁剪。

---

## 一、云端编译出 APK（不用装任何开发环境）

三条路，任选一条即可：

| 方式 | 适合谁 | 说明 |
|---|---|---|
| **A. Gitee 一键构建** | 想最省事 | 零配置，网页点按钮就出 APK，服务器在国内 |
| **B. Gitee Go 流水线** | 想推代码自动编 | 更像正规 CI，配置见 `gitee-go/build-apk.yml` |
| C. GitHub Actions | 已有 GitHub 且能推上去 | 配置已随项目提供，见 `.github/workflows/build.yml` |

> **为什么优先 Gitee**：本项目编译要用到的 Google 官方下载源（`dl.google.com`）
> 在国内网络下经常连不上，而 Gitee 的构建机在云端、自带 Android SDK 和内网依赖镜像，
> 正好绕开这个坑。而**在你自己电脑上本地编译反而更麻烦**（见第六节）。

---

### 方式 A：Gitee 一键构建（最省事，建议先试这个）

**前提**：有 Gitee 账号（https://gitee.com 注册，免费），并完成实名认证。

**第 1 步：新建空仓库**

1. 打开 https://gitee.com/projects/new
2. **仓库名称** 填 `StudyHub-TV`
3. 选「私有」或「开源」都行
4. **不要**勾选任何初始化选项（不需要 README / .gitignore / 许可证模板）
5. 点「创建」

**第 2 步：把代码推上去**

在 `D:\WorkBuddy\StudyHub-TV` 打开命令行（Git Bash / CMD / PowerShell 都行）：

```bash
# 把下面的 你的用户名 换成你的 Gitee 用户名
git remote add origin https://gitee.com/你的用户名/StudyHub-TV.git
git push -u origin main
```

> - 本地分支就是 `main`，推上去 Gitee 上也是 `main`，**这是正常的，不影响构建**。
> - 首次推送会弹窗要求输入 Gitee 的**账号和密码**（就是你的登录密码，不是 token）。
> - 如果报 `remote origin already exists`（之前配过 GitHub 的地址），先执行
>   `git remote remove origin` 再重新添加。

**第 3 步：把仓库语言标成 Android**

打开仓库 → **管理** → **基本信息** → **语言** 选 `Android` → 保存。

**第 4 步：一键构建**

1. 回到仓库首页，会出现「**下载 APK**」入口
2. 点 **新建构建** → **Java 版本选 17**（必须 17）→ 构建类型填 `assembleDebug`
3. 开始构建，等 3~8 分钟
4. 构建完成后，页面上就能**直接下载 APK**

> ⚠️ **签名选项不要勾「保留签名配置」**。
> 不勾时，Gitee 会自动生成一张临时证书帮你把 APK 签好，装到电视上就能用。
> （V1 本来就没配正式密钥，用的就是临时签名。）

---

### 方式 B：Gitee Go 流水线（推代码自动编译）

1. 仓库 → 顶部「**流水线**」→ 开通 Gitee Go
   - **需要账号已绑定手机号**（Gitee 的公共资源政策），免费开通
   - 免费额度：单个仓库 200 分钟（永久有效）+ 个人每月 500 分钟
2. 新建流水线 → 选「**空模板**」→ 把 **`gitee-go/build-apk.yml`** 的内容整段粘贴进在线编辑器 → 保存
3. 点「**运行**」立刻跑一次；以后每次 `git push` 会自动触发
4. 跑完在流水线页面的「**制品**」区下载 `StudyHub-TV-APK`

> 第一次跑请留意日志里「环境体检」那几行——它会打印构建机的 JDK 版本和 Android SDK 位置。
> 如果报「找不到 Android SDK」或「compileSdk 34 不存在」，把那段日志发我，我来调。

---

### 方式 C：GitHub Actions（项目已带配置）

如果你 GitHub 推得上去，这条完全是现成的，不用改任何东西：

1. https://github.com/new 新建空仓库，名字 `StudyHub-TV`，**不要**勾任何初始化选项
2. 推代码：
   ```bash
   git branch -M main
   git remote add origin https://github.com/你的用户名/StudyHub-TV.git
   git push -u origin main
   ```
   > 密码那一步要填 **Personal Access Token**（GitHub 头像 → Settings → Developer settings →
   > Personal access tokens → Tokens (classic) → 勾 `repo` → 生成），不是账号密码。
3. 推上去后点顶部 **Actions** 标签，等黄色圆点变**绿色对勾**（约 3~6 分钟）
4. 点进任务，页面底部 **Artifacts** 下载 **StudyHub-TV-APK**

> 如果显示**红色叉**，点进去把报错的红色文字发我，我来修。

---

### 最后一步：装到电视上

1. 解压下载到的包，里面通常有：
   - `app-debug.apk` —— 调试版，直接装
   - `app-release.apk` —— 正式版，**也是可以直接装的**（已用临时/debug 签名）
2. 把 APK 拷到 U 盘，插到电视上
3. 电视上用「文件管理」类 App 打开这个 APK 安装（首次需要允许「安装未知来源应用」）
4. 装好后在电视应用列表里找到 **StudyHub-TV** 打开

---

## 二、第一次使用

1. **添加服务器** —— 首页点「添加服务器」
   - 协议选 `SMB` 或 `WebDAV`
   - 服务器地址：填 NAS / 电脑的 IP，例如 `192.168.1.10`（不用带 `smb://`、`http://`）
   - 端口：SMB 默认 `445`，WebDAV 默认 `80`
   - 共享名（SMB 必填）：例如 `media`，就是 `\\192.168.1.10\media` 里的 `media`
   - 起始目录：填 `/` 表示从共享（或站点）根目录开始
   - 用户名 / 密码：匿名访问就留空
   - 点「测试连接」确认能通，再「保存」
2. 回到首页，**点一下这个服务器**就进入主界面了
3. 在服务器根目录下建好这些文件夹（名字含关键词即可，不区分大小写）：

   | 分类 | 文件夹名可以叫 |
   |---|---|
   | 图片 | `照片` `图片` `相册` `photos` `DCIM` |
   | 视频 | `视频` `录像` `videos` |
   | 音频 | `音乐` `音频` `music` |
   | 电影 | `电影` `影片` `蓝光` `movies` |
   | 电视剧 | `电视剧` `剧集` `美剧` `tvshows` |

   进了主界面点左侧分类，就会自动跳到对应文件夹。

---

## 三、遥控器按键

| 界面 | 按键 | 作用 |
|---|---|---|
| 主界面 | 方向键 | 移动焦点 |
| 主界面 | OK | 打开文件夹 / 播放文件 |
| 主界面 | 返回 | 回到上一级目录 |
| 主界面 | 菜单 | 弹出排序方式 |
| 主界面 | 长按 OK | 查看文件信息 |
| 播放器 | OK | 播放 / 暂停 |
| 播放器 | ← → | 快退 / 快进 10 秒 |
| 播放器 | ↑ ↓ | 调音量 |
| 播放器 | 返回 | 退出播放 |
| 图片 | ← → | 上一张 / 下一张 |
| 图片 | 菜单 | 放大（连续按继续放大） |

顶部的「切换账号」按钮可以在多个服务器之间一键切换。

---

## 四、技术选型（就一个记录，看不看都行）

| 项 | 选择 | 为什么 |
|---|---|---|
| 语言 | Kotlin | 官方主推 |
| 最低版本 | minSdk 21（Android 5.0） | 兼容老电视盒子 |
| 目标版本 | targetSdk 34 | 兼容新系统 |
| UI | XML 布局 + RecyclerView + 手动焦点管理 | 老盒子内存小，比 Jetpack Compose 更稳、包更小 |
| 播放内核 | **AndroidX Media3 / ExoPlayer 1.4.1** | ⚠️ Media3 1.9.0 起要求安卓 6.0，所以锁在 1.4.1 |
| SMB | **jcifs-ng 2.1.10** | ⚠️ smbj 用到 Java 方法句柄，打包要求 minSdk 26，安卓 5 用不了 |
| WebDAV | OkHttp + 自实现 PROPFIND | 轻量、可控 |
| 账号加密 | AES/CBC + 应用私有密钥 | 密码不落明文 |
| 编译 | Gradle 8.7 + AGP 8.5.2 + JDK 17 | Gitee / GitHub Actions 云端跑 |

---

## 五、已知限制（V1）

- **没有海报墙刮削**（按需求已去掉）
- **视频预览图的抽取方式**：先拉文件开头 8MB 到本地临时文件，再用系统解码器抽第一帧。
  绝大多数 MP4/MKV 都能出来；如果某部片子抽不出来（元数据在文件尾部的特殊情况），
  只要文件小于 80MB 会自动整体下载重试，再不行就显示占位图。
- **老盒子的硬件解码能力有限**：H.264 1080p 一般没问题，**H.265/HEVC 取决于芯片**，
  有些老盒子播不了（表现为有声音没画面）。后续版本可以加 libVLC 软解内核来兜底。
- 音频播放**没有做后台常驻**，息屏后可能暂停（后续版本加前台服务解决）。
- 列表是网格视图，**没有做列表视图**（后续版本补）。

---

## 六、想在电脑上本地编译（可选，但本机网络下不推荐）

需要自己装：**JDK 17**、**Android SDK（platform 34 + build-tools 34.0.0）**。

```bash
cd StudyHub-TV
echo "sdk.dir=你的Android SDK路径" > local.properties
./gradlew assembleDebug      # 产物在 app/build/outputs/apk/debug/
```

Windows 上把 `./gradlew` 换成 `gradlew.bat`。

> ⚠️ **实测提醒（2026-10-14 于本机测试）**：
> - ✅ `services.gradle.org`、`github.com`、`gitee.com`、阿里云 Maven 镜像 —— 都通
> - ❌ `dl.google.com` —— **不通**，而 Android SDK 的 platform / build-tools 正是从这里下载
> - ❌ 清华、中科大、阿里云几个老牌 `android/repository` 镜像 —— **现已全部 404 下线**
>
> 结论：这台机器上要本地编译，得先自己解决 Android SDK 的获取（比如代理，或从别的
> 机器把 SDK 目录拷过来）。**所以云端编译（见第一节）是更省事的路。**

---

## 七、开源许可

SMB 客户端使用 [jcifs-ng](https://github.com/agno3/jcifs-ng)（LGPL 2.1），
播放内核使用 [AndroidX Media3](https://github.com/androidx/media)（Apache 2.0）。

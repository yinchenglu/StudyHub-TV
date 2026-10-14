# GitHub 全自动上传编译 —— 你只需做 1 件事

> 本文件由自动化流程维护。当前方案：**纯 `api.github.com` 通道**，不需要 SSH 密钥。

## 一、为什么走 api.github.com（本机实测数据）

| 通道 | 实测结果 | 能否用 |
|---|---|---|
| `api.github.com`（接口） | ✅ HTTP 200，**0.47 秒** | **用这个** |
| `github.com`（网页/HTTPS git） | ⚠️ 能返回 200 头，但**传输仅约 20KB/s**，`git ls-remote` 直接超时 | ✘ 不可用 |
| `objects.githubusercontent.com`（产物下载） | ✅ 可达 | ✔ |
| `*.blob.core.windows.net`（产物下载跳转目标） | ✅ 可达 | ✔ |

**结论**：`github.com` 主站被限速到无法传输，`git push` 走不通；
但 `api.github.com` 极快，且编译产物的下载域名全部可达 —— 所以整条链路**全部走 API**：

- 上传代码 → Git Data API（建 blob → 建 tree → 建 commit → 更新分支引用）
- 触发编译 → 更新分支引用本身就是一次 push 事件，工作流自动启动
- 查状态 / 看日志 / 下 APK → Actions API

这样**不需要 SSH 密钥，也不需要 git push**，你少一件事。

---

## 二、你要做的唯一一件事：给我一个 GitHub Token

### 第 1 步：生成 token

1. 打开 https://github.com/settings/tokens
2. 点 **Generate new token** → 选 **Generate new token (classic)**
   （必须是 classic，fine-grained 的权限模型对不上）
3. **Note** 随便填，例如 `StudyHub-TV 自动上传`
4. **Expiration** 建议选 `30 days`（到期自动失效，更安全）
5. **只勾这两个权限**：

   | 勾选项 | 为什么需要 |
   |---|---|
   | ☑ `repo` | 建仓库、上传代码、下载编译产物 |
   | ☑ `workflow` | 允许推送 `.github/workflows/` 下的编译配置（**不勾会被 GitHub 拒绝**） |

   > 走 API 后不再需要 `write:public_key`（那项是给 SSH 方案用的）。

6. 拉到最下面点 **Generate token**
7. **立刻复制那串 token**（`ghp_` 开头）—— 页面关掉就再也看不到了

### 第 2 步：把 token 存到本地文件（别贴进对话）

在记事本里粘贴 token，另存为：

```
D:\WorkBuddy\github-token.txt
```

> **为什么不让你直接发给我**：token 等同账号权限，贴在对话里会留存在聊天记录中。
> 存成本地文件我只读取使用，聊天记录里不会出现 token。
> 用完你随时可以在 https://github.com/settings/tokens 一键撤销它。

### 第 3 步：告诉我一句「token 放好了」

剩下的全部由我完成 👇

---

## 三、我接下来会自动做的事（脚本已就绪）

执行 `D:\WorkBuddy\_deploy\gh_deploy.py`，一次跑完 7 步：

| 步骤 | 动作 |
|---|---|
| 1 | 读 token，调 `/user` 验证有效性与剩余额度 |
| 2 | 自动创建**私有**仓库 `StudyHub-TV`（已存在则复用） |
| 3 | 用 Git Data API 上传全部 68 个文件（含 `gradlew` 可执行位） |
| 4 | 更新分支引用 → **自动触发** `.github/workflows/build.yml` |
| 5 | **持续轮询**编译进度，逐个作业、逐个步骤显示成败（你不用盯网页） |
| 6 | 编译成功 → 用 Actions API **把 APK 下载到本地** |
| 7 | 解压并把 `app-debug.apk` / `app-release.apk` 直接交给你 |

编译失败的话，会把失败的作业与步骤列出来，我据此改代码重推。

**脚本可用的执行方式：**

```bash
# 全流程（默认）
python gh_deploy.py

# 只验证 token 是否可用
python gh_deploy.py --check

# 只下载指定那次编译的产物
python gh_deploy.py --run-id 123456789

# 跳过上传，只轮询最近一次编译
python gh_deploy.py --no-upload
```

> 脚本已做过真实连通性验证：假 token 打 `/user` 返回 401 耗时 0.73 秒（鉴权链路正常）、
> 中文与二进制文件的 base64 往返一致、跨域跳转时自动剥离 Authorization 头
> （产物下载会 302 到 Azure Blob 并自带签名，带着 Authorization 会被拒）。

---

## 四、产物会放在哪

```
D:\WorkBuddy\_deploy\output\
  ├─ StudyHub-TV-APK.zip          ← 原始产物
  └─ StudyHub-TV-APK\
       ├─ app-debug.apk           ← 调试版，直接装
       └─ app-release.apk         ← 正式版，已用 debug 签名，也能直接装
```

装到电视：拷到 U 盘 → 插电视 → 用「文件管理」类 App 打开 APK 安装
（首次需允许「安装未知来源应用」）→ 在应用列表找到 **StudyHub-TV**。

---

## 五、备选方案（API 走不通时再用）

本机已备好 SSH 密钥，如果哪天 API 被限流或不可用，可切回 SSH 推送：

| 文件 | 用途 |
|---|---|
| `C:\Users\MI\.ssh\github_studyhub` | 私钥（已用 Windows ACL 加固，仅你可读） |
| `C:\Users\MI\.ssh\github_studyhub.pub` | 公钥 |
| `C:\Users\MI\.ssh\config` | 让 `github.com` 自动走 443 端口（`ssh.github.com:443` 实测可达） |

**公钥（如需手动添加，复制这一整行）：**

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINJVEH/Jo+UyKq6omMNVHOeNENkTs4kxa03Iymg3x27u StudyHub-TV
```

路径：头像 → **Settings** → **SSH and GPG keys** → **New SSH key** → 粘贴 → Add。
指纹可核对：`SHA256:B/cfRrRZkF9LUeQ/PZr0zDfGpXdHVeovAX/5v193/QA`

> Gitee 那对密钥 `gitee_studyhub` 也还在，以后想用 Gitee 可直接复用。

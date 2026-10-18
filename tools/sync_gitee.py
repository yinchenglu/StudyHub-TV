#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把一次构建镜像到 Gitee。

做的事（按顺序，任何一步失败都只报警不影响 GitHub 那边的发布）：
  1. 用令牌认人（GET /user），拿到 Gitee 用户名
  2. 在这个用户名下找同名仓库；没有就自动建一个（默认私有）
  3. git push 代码（默认分支）+ 所有标签，把仓库做成单向镜像
  4. 如果这次是打 v 标签：在 Gitee 建/更新同名发行版，把 dist/*.apk 传成附件

需要的环境变量：
  GITEE_TOKEN        必填  Gitee 私人令牌（仓库 Secrets 里的 GITEE_TOKEN）
  GITEE_REPO_PATH    可选  完整路径 owner/repo，填了就直接用它，不再自动找/建
  GITEE_REPO_NAME    可选  Gitee 仓库名，默认取 GitHub 仓库名
  GITEE_REPO_PRIVATE 可选  自动建仓时是否私有，默认 true
  GITEE_BRANCH       可选  推哪个分支，默认 main
  GITHUB_REF / GITHUB_REF_NAME   由 Actions 自动提供

本地试跑（不会真推，只打印计划）：
  GITEE_TOKEN=xxx python3 tools/sync_gitee.py --dry-run
"""

import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

API = "https://gitee.com/api/v5"
TIMEOUT = 60
UPLOAD_TIMEOUT = 600
DRY = "--dry-run" in sys.argv

TOKEN = (os.environ.get("GITEE_TOKEN", "").strip()
         or os.environ.get("GITEE_TOKEN_VAR", "").strip())
REF = os.environ.get("GITHUB_REF", "")
REF_NAME = os.environ.get("GITHUB_REF_NAME", "")
DEFAULT_BRANCH = os.environ.get("GITEE_BRANCH", "").strip() or "main"
REPO_NAME = (
    os.environ.get("GITEE_REPO_NAME", "").strip()
    or os.environ.get("GITHUB_REPOSITORY", "").split("/")[-1]
    or "StudyHub-TV"
)
# 明确指定了 owner/repo 就照着用：镜像仓库名和 GitHub 不一样时靠这个兜底
REPO_PATH = os.environ.get("GITEE_REPO_PATH", "").strip().strip("/")
PRIVATE = os.environ.get("GITEE_REPO_PRIVATE", "true").strip().lower() != "false"
IS_TAG = REF.startswith("refs/tags/v")
DIST = os.environ.get("DIST_DIR", "dist")


# ----------------------------------------------------------------------
# 小工具
# ----------------------------------------------------------------------
def log(msg):
    print(msg, flush=True)


def mask(text):
    """任何要打印的文本都要过一遍，别把令牌漏进构建日志。"""
    if not text:
        return text
    s = str(text)
    if TOKEN and TOKEN in s:
        s = s.replace(TOKEN, "***")
    return s


def warn(msg):
    # ::warning:: 会让 GitHub 总结页里出现一条黄色提示
    log("::warning::" + mask(msg))


def die(msg):
    log("::error::" + mask(msg))
    sys.exit(1)


def pubspec_tag():
    """把 pubspec 的 version: 1.4.0+2006 变成标签名 v1.4.0。"""
    try:
        with open("pubspec.yaml", encoding="utf-8") as f:
            for line in f:
                if line.startswith("version:"):
                    return "v" + line.split(":", 1)[1].strip().split("+")[0]
    except OSError:
        pass
    return ""


def has_local_tag(tag):
    """仓库里真的有这个 v 标签，才算"官方发布过"。"""
    return subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", "refs/tags/%s" % tag],
        capture_output=True, text=True).returncode == 0


def pick_release_tag():
    """决定这次要给哪个标签建发行版。

    三种来源，优先级从高到低：
      1. 本次就是打 v 标签触发的 → 用触发的那个标签
      2. 手动指定了 GITEE_RELEASE_TAG（网页 Run workflow 时填）→ 用它
      3. 当前代码的版本号对应一个**已存在**的 v 标签 → 用它补建

    第 3 条是为了"自愈"：GitHub 上早就发过版，但 Gitee 那次同步因为令牌没配
    失败了，发行版就永远是空的。之后再往 main 推任何一次代码，都能把缺的那个
    补上，不用为了修这个再去挪标签或发新版本。
    """
    if IS_TAG and REF_NAME:
        return REF_NAME, "本次由 %s 标签触发" % REF_NAME

    override = os.environ.get("GITEE_RELEASE_TAG", "").strip()
    if override:
        return override, "手动指定 GITEE_RELEASE_TAG"

    guess = pubspec_tag()
    if guess and has_local_tag(guess):
        return guess, "当前版本 %s 已打标签，补齐 Gitee 上缺失的发行版" % guess
    return "", ""


# ----------------------------------------------------------------------
# API
# ----------------------------------------------------------------------
def api(method, path, params=None, body=None):
    q = dict(params or {})
    q["access_token"] = TOKEN
    url = API + path + "?" + urllib.parse.urlencode(q)
    data = None
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json; charset=UTF-8")
    req.add_header("Accept", "application/json")
    req.add_header("User-Agent", "StudyHub-TV-CI")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        raise RuntimeError("%s %s -> HTTP %s %s" % (method, path, e.code, detail))
    except urllib.error.URLError as e:
        raise RuntimeError("%s %s -> 连不上 Gitee：%s" % (method, path, e.reason))


def upload_asset(full_name, release_id, filepath):
    """multipart 上传一个附件。

    这里踩过一个坑（2026-10-18，v1.4.0）：用 urllib 直接 POST，14.6MB 的 APK
    从 GitHub 机房传到 Gitee 会在 sendall 上卡死，最后报
    "URLError: The write operation timed out"（600 秒一点进度都没有）。
    原因不是文件太大，而是这条跨境链路上长连接容易被中间设备掐掉、而且
    urllib 一旦卡住只能等到超时，没有"慢到一定程度就放弃重来"的能力。

    所以改成用 curl，理由是它能干三件 urllib 干不了的事：
      * --speed-limit/--speed-time：传输掉到 2KB/s 超过 120 秒就主动放弃，
        不用干等十分钟；
      * --retry + 外层重试：断了立刻重来，而不是整条流程从头再跑一遍；
      * -H "Expect:"：关掉 100-continue，避免网关先挂住握手。
    curl 不存在（本地 Windows 跑脚本时）就退回 urllib。
    """
    filename = os.path.basename(filepath)
    size = os.path.getsize(filepath)
    if size > 100 * 1024 * 1024:
        raise RuntimeError("%s 有 %.1f MB，超过 Gitee 附件 100MB 上限"
                           % (filename, size / 1048576.0))

    url = "%s/repos/%s/releases/%s/attach_files" % (API, full_name, release_id)
    if shutil.which("curl"):
        return _upload_with_curl(url, filepath, filename)
    return _upload_with_urllib(url, filepath, filename)


def _upload_with_curl(url, filepath, filename, attempts=3):
    ctype = mimetypes.guess_type(filename)[0] or "application/octet-stream"
    last = ""
    for attempt in range(1, attempts + 1):
        # 用 tempfile 拼路径而不是写死 /tmp：本地 Windows 上 curl.exe 是不认
        # "/tmp" 的（会报 curl: (23) client returned ERROR on write）。
        resp = os.path.join(tempfile.gettempdir(),
                            "gitee-upload-%d.json" % attempt)
        started = time.time()
        p = subprocess.run([
            "curl", "-sS", "--http1.1",
            "-H", "Expect:",                     # 别走 100-continue
            "-H", "User-Agent: StudyHub-TV-CI",
            "--max-time", "1800",  # 实测一次 14MB 要 850 秒，别卡太紧
            "--speed-limit", "4096",             # 低于 4KB/s ...
            "--speed-time", "90",                # ... 持续 90 秒就放弃重来
            "-o", resp,
            "-w", "%{http_code}",
            "-F", "access_token=%s" % TOKEN,
            "-F", "file=@%s;type=%s" % (filepath, ctype),
            url,
        ], capture_output=True, text=True)

        code = (p.stdout or "").strip()[-3:]
        body = ""
        if os.path.exists(resp):
            with open(resp, "r", encoding="utf-8", errors="replace") as f:
                body = f.read()
            os.remove(resp)

        if code in ("200", "201"):
            log("    完成，用时 %.0f 秒" % (time.time() - started))
            try:
                return json.loads(body) if body.strip() else {}
            except ValueError:
                return {}

        # curl 自己失败（超时/断流）时 stdout 里不是 HTTP 码，p.stderr 才有原因
        reason = mask((p.stderr or "").strip())[:200] or "HTTP %s" % code
        last = "%s %s" % (reason, mask(body)[:200])
        log("    第 %d/%d 次失败（%.0f 秒）：%s"
            % (attempt, attempts, time.time() - started, last))
        if attempt < attempts:
            time.sleep(10)
    raise RuntimeError("上传 %s 失败（已试 %d 次）：%s" % (filename, attempts, last))


def _upload_with_urllib(url, filepath, filename):
    """curl 不存在时的退路（本地 Windows 上跑脚本会走这里）。"""
    boundary = "----studyhub" + uuid.uuid4().hex
    ctype = mimetypes.guess_type(filename)[0] or "application/octet-stream"
    head = (
        "--%s\r\n"
        'Content-Disposition: form-data; name="file"; filename="%s"\r\n'
        "Content-Type: %s\r\n\r\n"
        % (boundary, filename, ctype)
    ).encode("utf-8")
    tail = ("\r\n--%s--\r\n" % boundary).encode("utf-8")
    with open(filepath, "rb") as f:
        payload = head + f.read() + tail

    req = urllib.request.Request(
        url + "?access_token=" + urllib.parse.quote(TOKEN, safe=""),
        data=payload, method="POST")
    req.add_header("Content-Type", "multipart/form-data; boundary=%s" % boundary)
    req.add_header("Accept", "application/json")
    req.add_header("User-Agent", "StudyHub-TV-CI")
    try:
        with urllib.request.urlopen(req, timeout=UPLOAD_TIMEOUT) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        raise RuntimeError("上传 %s 失败：HTTP %s %s" % (filename, e.code, detail))
    except urllib.error.URLError as e:
        raise RuntimeError("上传 %s 失败：%s" % (filename, e.reason))


def release_asset_names(full_name, release_id, tag):
    """问清楚"这个发行版现在挂了哪些附件"。

    两条路，因为两条都不完全靠谱（2026-10-18 v1.4.0 实测）：
      * GET /releases/{id}/attach_files —— 官方接口，正常时会返回列表；
      * 抓发行版页面。`GET /releases/tags/{tag}` 返回的对象里根本没有
        attach_files 字段，历史上就是靠它做校验，结果每次都误报"附件没查到"。
    两条都空就当真的没有（宁可重传，也别把已有附件当成没有、也不能反过来）。
    """
    names = set()
    try:
        files = api("GET", "/repos/%s/releases/%s/attach_files"
                    % (full_name, release_id)) or []
        if isinstance(files, dict):
            files = files.get("files") or files.get("attach_files") or []
        for f in files:
            if isinstance(f, dict):
                names.add(f.get("name") or f.get("file_name"))
    except RuntimeError as e:
        warn("读附件列表失败（%s），改用页面兜底" % e)

    names = {n for n in names if n}
    if names:
        return names

    try:
        url = "https://gitee.com/%s/releases/tag/%s" % (full_name, tag)
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            html = r.read().decode("utf-8", "replace")
        names = {os.path.basename(n) for n in re.findall(r"[\w.\-]+\.apk", html)}
    except Exception:
        pass
    return names


# ----------------------------------------------------------------------
# git
# ----------------------------------------------------------------------
def git(args, cwd="."):
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    p = subprocess.run(
        ["git"] + args,
        cwd=cwd,
        capture_output=True,
        text=True,
        env=env,
    )
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode != 0:
        raise RuntimeError("git %s 失败：\n%s" % (" ".join(args[:2]), mask(out[-1200:])))
    return mask(out)


def main():
    if not TOKEN:
        die("没配 GITEE_TOKEN —— 同步到 Gitee 需要它（secrets 和 vars 里都没读到）。\n"
            "逐条核对：\n"
            "  1. 打开 https://github.com/yinchenglu/StudyHub-TV/settings/secrets/actions\n"
            "     地址里的仓库名必须是 StudyHub-TV —— 建到 StudyHub 那边本仓库读不到；\n"
            "  2. 那一页要有「Repository secrets」区块，名字正好是 GITEE_TOKEN\n"
            "     （不是 Variables 标签页，不是 Environment secrets，没有多余空格）；\n"
            "  3. 建在 Environment 里的令牌，job 不声明 environment 就读不到。")
    # 只打印长度，不打印内容：长度能区分"完全没读到"和"读到了但令牌不对"
    log("→ 已读到 GITEE_TOKEN（%d 个字符）" % len(TOKEN))

    log("→ 校验令牌")
    me = api("GET", "/user")
    login = (me or {}).get("login") or ""
    if not login:
        die("令牌无效：GET /user 没返回 login")
    log("  Gitee 账号：%s" % login)

    # ---------- 找仓库，没有就建 ----------
    full_name = None
    if REPO_PATH and "/" in REPO_PATH:
        full_name = REPO_PATH
        log("→ 使用指定仓库 %s" % full_name)
        try:
            info = api("GET", "/repos/%s" % full_name) or {}
            log("  已存在：%s（私有=%s）" % (info.get("full_name", full_name),
                                             info.get("private")))
        except RuntimeError as e:
            die("仓库 %s 读不到：%s\n（检查 GITEE_REPO_PATH 拼写，或令牌有没有权限）"
                % (full_name, e))
    else:
        log("→ 找仓库 %s" % REPO_NAME)
        for page in range(1, 6):
            try:
                repos = api("GET", "/user/repos",
                            {"per_page": 100, "page": page, "sort": "full_name"}) or []
            except RuntimeError as e:
                warn("列仓库失败（%s），改用 %s/%s 直接试" % (e, login, REPO_NAME))
                repos = []
                break
            for r in repos:
                if (r.get("path") or r.get("name") or "").lower() == REPO_NAME.lower():
                    full_name = r.get("full_name") or ("%s/%s" % (login, r.get("path")))
                    break
            if full_name or len(repos) < 100:
                break

    if not full_name:
        full_name = "%s/%s" % (login, REPO_NAME)
        log("  没找到，自动创建 %s（私有=%s）" % (full_name, PRIVATE))
        if DRY:
            log("  [dry-run] 跳过创建")
        else:
            try:
                created = api("POST", "/user/repos", body={
                    "name": REPO_NAME,
                    "path": REPO_NAME,
                    "private": PRIVATE,
                    "auto_init": False,
                    "description": "StudyHub TV 的镜像仓库（由 GitHub Actions 自动同步，请勿直接提交）",
                }) or {}
                full_name = created.get("full_name") or full_name
            except RuntimeError as e:
                die("建仓库失败：%s\n（令牌需要有 projects 权限；也可以在 Gitee 上先手动建一个空仓库）" % e)
    log("  仓库：%s" % full_name)

    # ---------- 推代码 ----------
    # 令牌放 URL 里是 Gitee HTTPS 推送的常规做法；输出统一过 mask()，
    # 失败时日志里也只会看到 ***。
    push_url = "https://%s:%s@gitee.com/%s.git" % (
        urllib.parse.quote(login, safe=""),
        urllib.parse.quote(TOKEN, safe=""),
        full_name,
    )
    # 用远端跟踪分支做源，而不是 HEAD：
    # 打旧标签构建时 HEAD 是那个 tag，直接推 HEAD 会把 Gitee 的 main 往回倒。
    has_branch = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet",
         "refs/remotes/origin/%s" % DEFAULT_BRANCH],
        capture_output=True, text=True).returncode == 0
    src = ("refs/remotes/origin/%s" % DEFAULT_BRANCH) if has_branch else "HEAD"

    log("→ 推分支 %s（源：%s）和标签" % (DEFAULT_BRANCH, src))
    if DRY:
        log("  [dry-run] git push %s %s:refs/heads/%s --force" % (push_url, src, DEFAULT_BRANCH))
    else:
        try:
            git(["push", "--no-verify", "--force", push_url,
                 "%s:refs/heads/%s" % (src, DEFAULT_BRANCH)])
            git(["push", "--no-verify", "--force", push_url, "--tags"])
        except RuntimeError as e:
            die("%s\n（检查令牌是否有 projects 写权限、仓库是否为空仓库）" % e)

    # ---------- 发行版 ----------
    tag, why = pick_release_tag()
    if not tag:
        log("→ 本次不是 v 标签构建，只镜像代码，不发 Gitee 发行版")
        return

    log("→ 处理 Gitee 发行版 %s（%s）" % (tag, why))
    release = None
    try:
        release = api("GET", "/repos/%s/releases/tags/%s" % (full_name, tag))
    except RuntimeError as e:
        log("  还没有发行版（%s），新建一个" % mask(str(e))[:120])

    if not release:
        body = (
            "与 GitHub 发布保持一致：%s\n\n"
            "安装方法见仓库 README。\n"
            "> 本发行版由 GitHub Actions 自动同步，请勿在 Gitee 上手工改。\n"
            % (os.environ.get("GITHUB_SERVER_URL", "https://github.com")
               + "/" + os.environ.get("GITHUB_REPOSITORY", "") + "/releases/tag/" + tag)
        )
        if DRY:
            log("  [dry-run] 跳过创建发行版")
            return
        release = api("POST", "/repos/%s/releases" % full_name, body={
            "tag_name": tag,
            "name": "StudyHub TV %s" % tag,
            "body": body,
            "target_commitish": DEFAULT_BRANCH,
            "prerelease": False,
        })
        log("  已创建发行版 #%s" % release.get("id"))

    rid = release.get("id")
    if not rid:
        die("Gitee 没有返回发行版 id，无法上传附件")

    # 已经传过同名的就先跳过，重复跑不会堆一串重复文件
    existing = release_asset_names(full_name, rid, tag)

    apks = sorted(
        os.path.join(DIST, n) for n in os.listdir(DIST)
        if n.lower().endswith(".apk")
    ) if os.path.isdir(DIST) else []
    if not apks:
        warn("dist/ 里没有 APK，Gitee 发行版只建了壳")
        return

    failed = []
    for path in apks:
        name = os.path.basename(path)
        if name in existing:
            log("  %s 已存在，跳过" % name)
            continue
        if DRY:
            log("  [dry-run] 上传 %s" % name)
            continue
        log("  上传 %s（%.1f MB）" % (name, os.path.getsize(path) / 1048576.0))
        try:
            res = upload_asset(full_name, rid, path)
            log("    -> %s" % (res.get("browser_download_url") or "已上传"))
        except RuntimeError as e:
            # 一个包失败不影响另一个：两个都传完再统一报错，
            # 这样重跑时已经传上去的那个会被"已存在，跳过"，不会白传。
            log("::error::" + mask(str(e)))
            failed.append(name)

    if failed:
        die("这些附件没传上去：%s（发行版本身已建好，重跑会自动跳过已成功的）"
            % ", ".join(failed))

    # 传完再读一遍，确认真的落地了 —— 不然 job 绿着、用户点进去啥也没有，
    # 比直接报错更难查（v1.4.0 第一次跑就是这么被坑的）。
    if not DRY:
        try:
            landed = release_asset_names(full_name, rid, tag)
            names = {os.path.basename(p) for p in apks}
            missing = names - landed
            if missing:
                warn("发行版存在，但这几个附件没查到：%s（可能接口只返回部分，"
                     "先去页面确认一眼再重跑）" % ", ".join(sorted(missing)))
            else:
                log("  回读确认：%d 个附件都在" % len(landed))
        except RuntimeError as e:
            warn("回读发行版失败：%s" % e)

    log("✔ Gitee 同步完成：https://gitee.com/%s/releases/tag/%s" % (full_name, tag))


if __name__ == "__main__":
    main()

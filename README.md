# SolveLog

A native macOS app that collects **your own** competitive-programming submissions from several online
judges into one local database, and shows them as one dashboard: solved counts, a year-long activity
heatmap, difficulty distributions and your recent submissions.

> **Built with AI.** The code of SolveLog was written mainly by **Claude Opus 5.5** (Anthropic's AI model),
> working from the maintainer's requirements and feedback. The maintainer decided what the app should do,
> tested it against real accounts and reviewed the results; Claude wrote the Swift app, the dashboard,
> the userscript and this README. Like any software — and especially AI-written software — it may contain
> mistakes: please read the code before trusting it with your sign-in, and
> [open an issue](https://github.com/solvelog/solvelog/issues) if something looks wrong.
>
> **由 AI 编写。** SolveLog 的代码主要由 **Claude Opus 5.5**（Anthropic 的 AI 模型）根据维护者的需求和反馈完成。
> 维护者负责确定功能、用真实账号测试并检查结果；Swift 应用、仪表盘页面、油猴脚本和本 README 均由 Claude 编写。
> 和所有软件一样（尤其是 AI 编写的软件），其中可能存在错误：在把登录信息交给它之前请先阅读代码，发现问题欢迎提
> [Issue](https://github.com/solvelog/solvelog/issues)。

| Judge | How SolveLog reads it | Sign-in needed |
|---|---|---|
| Codeforces | official API `user.status` | no |
| AtCoder | [AtCoder Problems](https://kenkoooo.com/atcoder/) API | no |
| CodeChef | public recent-activity endpoint | no |
| LibreOJ | public `querySubmission` API | no |
| UOJ (uoj.ac) | submission list pages | yes (any account's cookie) |
| Luogu | the practice page *you* open, sent by the userscript | no (SolveLog never contacts Luogu) |
| Project Euler | the Progress page *you* open, sent by the userscript | no (SolveLog never contacts PE) |

* Several accounts per judge are merged (team submissions are counted once).
* Difficulty charts use each judge's own scale: Luogu's nine levels (identical to the 难易度统计 on your
  Luogu practice page), Codeforces problem ratings, AtCoder Problems difficulty in AtCoder colours,
  CodeChef difficulty grouped by stars, Project Euler levels 0–40 — plus optional [clist.by](https://clist.by)
  ratings across judges.
* Everything stays on your Mac. Sign-in cookies and API keys are kept in the macOS Keychain and are
  only ever sent back to the site they came from.

## Install

Requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/solvelog/solvelog.git && cd solvelog
scripts/build-app.sh --install      # builds build/SolveLog.app and copies it to /Applications
```

The app is ad-hoc signed. The first time, open it with right-click → **Open**. After rebuilding,
macOS may ask once whether SolveLog may read its own Keychain items — choose **Always Allow**.

## Getting started

1. Open **Settings** (⌘,) → **Accounts** and enter your handles (comma separated).
2. Install the userscript (below). Send your Luogu practice page and Project Euler progress page;
   for UOJ, import a sign-in.
3. Click **Sync**. The first sync of a large account can take a few minutes; later syncs are incremental
   and take seconds. Different judges are fetched in parallel; each judge is fetched slowly on purpose.

### The userscript

Install [Tampermonkey](https://www.tampermonkey.net/), then open
<https://github.com/solvelog/solvelog/raw/main/userscript/solvelog-cookies.user.js> — Tampermonkey
offers to install it (and keeps it updated). It adds a button to the bottom right of the pages below.

### Luogu and Project Euler: send the page you are looking at

SolveLog never contacts Luogu or Project Euler. Luogu runs an automatic ban system for automated
access and warns against handing cookies to tools
([announcement](https://www.luogu.com/discuss/1337298)), so no cookie is used for either site:

* **Luogu practice page** (profile → 练习, `luogu.com.cn/user/<uid>/practice`) — your solved problems
  with their official difficulty (the chart matches the page's 难易度统计 exactly) and the problems you
  tried but have not solved yet.
* **Luogu record list** (评测记录 filtered to you, `luogu.com.cn/record/list?user=<uid>`) — the 20
  submissions shown on that page, wrong answers included. Open page 1 now and then to keep recent
  submissions, the heatmap and acceptance up to date (add page 2, 3… if you submitted more than 20 times
  since). Older history is only what you import page by page — SolveLog never pages through it for you.
* **Project Euler** — open <https://projecteuler.net/progress> and click **Send to SolveLog**. The
  script copies the solved-problem table (including completion times).

Then press **⌘⇧V** in SolveLog (or Settings → Sign-in → *Paste from Clipboard*). Repeat whenever you
want to update.

### UOJ: importing a sign-in

UOJ only shows submissions to signed-in users, and its session cookie is *HttpOnly*, so no web page can
read it. The userscript can, once you allow it:

1. Tampermonkey → **Settings** → *Config mode*: **Advanced** → *Security* →
   **Allow scripts to access cookies: All**. (The default excludes HttpOnly cookies.
   This setting applies to every userscript you have installed — only use scripts you trust.)
2. Sign in on uoj.ac and click **Copy to SolveLog**.
3. Switch to SolveLog and press **⌘⇧V**. SolveLog validates the cookie, stores it in the Keychain,
   clears the clipboard and syncs UOJ.

When the sign-in expires, the sync log says so — just repeat steps 2–3.

UOJ watches for automated access, so SolveLog only contacts it when you click **Sync** (never on
launch), at most once every 30 minutes, waits a random 4–9 s between requests, reads at most 10 pages per
sync in total across all your UOJ handles (a long history fills in over several syncs), and on any
rate-limit response stops immediately and leaves UOJ alone for 6 hours. Using a sign-in cookie in any
tool is still at your own risk — please don't loosen these limits.

### Optional: clist.by ratings

Create a free account on [clist.by](https://clist.by), copy your API key from
<https://clist.by/api/v4/doc/> and enter it under **Settings → Ratings**. The first download takes about
five minutes (the free API allows 10 requests per minute) and is refreshed weekly.

## Data

* Database and settings: `~/Library/Application Support/SolveLog/` (override with `SOLVELOG_HOME`).
* **Settings → Data** exports/imports all submissions as CSV or JSON, and exports/imports settings
  (handles and options only — never cookies or keys).

### Command line

The same binary has a headless mode, e.g. for a cron job:

```bash
/Applications/SolveLog.app/Contents/MacOS/SolveLog --cli sync          # or: sync --full codeforces
/Applications/SolveLog.app/Contents/MacOS/SolveLog --cli stats
/Applications/SolveLog.app/Contents/MacOS/SolveLog --cli export ~/solvelog.csv
```

Run `--cli` without arguments for all commands.

## Being a good citizen

SolveLog only reads data that belongs to you, through the same pages and public APIs your browser
uses, with deliberate pauses between requests and back-off on HTTP 429. It does not try to get around
bot protection: judges that block automated access behind a challenge (for example QOJ) are not
supported. Please keep it that way in contributions.

SolveLog is not affiliated with or endorsed by any of the judges above.

## Development

```bash
swift build                 # debug build
swift run SolveLog          # run the app from source (uses Resources/web/index.html)
```

* `Sources/SolveLog/Platforms/` — one file per judge
* `Sources/SolveLog/Core/` — database, HTTP client, settings/Keychain, ratings, sync engine
* `Sources/SolveLog/Data/` — dashboard JSON, import/export, cookie import
* `Resources/web/index.html` — the dashboard (plain HTML/JS, no build step)

## License

Copyright © 2026 SolveLog contributors.

SolveLog is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version. See [LICENSE](LICENSE).

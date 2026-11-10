**Companion userscript for [SolveLog](https://github.com/solvelog/solvelog)**, a free, open-source macOS app (GPL-3.0) that collects your own competitive-programming submissions into one local dashboard.

It adds a button to the bottom-right of these pages:

| Page | What it copies |
|---|---|
| Luogu practice page (`/user/<uid>/practice`) | Your solved and tried problems with official difficulty — read from data already embedded in the page |
| Luogu record list (`/record/list?user=<uid>`) | The 20 submissions shown on that page (refuses if it shows other people's submissions) |
| Project Euler progress page | Your solved-problem table |
| UOJ (signed in) | Your UOJ sign-in cookie |

**Privacy:** everything is copied **only to your clipboard**. The script sends nothing to any server and makes no network requests. Paste it into SolveLog with ⌘⇧V; SolveLog clears the clipboard afterwards. For Luogu and Project Euler, no cookie is read at all.

**UOJ only:** reading the HttpOnly sign-in cookie requires Tampermonkey → Settings → Config mode: Advanced → Security → "Allow scripts to access cookies: All". This setting applies to all your userscripts, so only enable it if you trust them. Luogu and Project Euler work without it.

The code was written mainly by Claude Opus 5.5 (AI). Please read it before trusting it with your sign-in — it's short and unobfuscated. Bugs and questions: [GitHub Issues](https://github.com/solvelog/solvelog/issues).

---

**[SolveLog](https://github.com/solvelog/solvelog) 的配套脚本。** SolveLog 是一个免费开源（GPL-3.0）的 macOS 应用，把你自己在各个 OJ 上的提交记录汇总到本地的统计面板里。

脚本会在以下页面右下角添加一个按钮：

| 页面 | 复制的内容 |
|---|---|
| 洛谷练习页（`/user/<uid>/practice`） | 已通过和尝试过的题目及官方难度，直接读取页面里已有的数据 |
| 洛谷评测记录页（`/record/list?user=<uid>`） | 当前页的 20 条提交记录（页面里有别人的记录时会拒绝复制） |
| Project Euler 进度页 | 已解决的题目表格 |
| UOJ（已登录） | UOJ 登录 Cookie |

**隐私：** 所有内容**只复制到剪贴板**，脚本不向任何服务器发送数据，也不发起任何网络请求。在 SolveLog 里按 ⌘⇧V 粘贴后，SolveLog 会清空剪贴板。洛谷和 Project Euler 完全不读取 Cookie。

**仅 UOJ 需要：** 读取 HttpOnly 登录 Cookie，需要在 Tampermonkey → 设置 → 配置模式：高级 → 安全 →「允许脚本访问 Cookie」中选择「全部」。这个设置对你安装的所有脚本都生效，请只在信任它们时开启。洛谷和 Project Euler 不需要改这个设置。

代码主要由 Claude Opus 5.5（AI）编写。在把登录信息交给它之前，请先阅读代码（代码很短，没有混淆）。问题反馈：[GitHub Issues](https://github.com/solvelog/solvelog/issues)。

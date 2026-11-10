// ==UserScript==
// @name         SolveLog Sign-in Helper
// @name:zh-CN   SolveLog 导入助手
// @namespace    https://github.com/solvelog
// @homepageURL  https://github.com/solvelog/solvelog
// @supportURL   https://github.com/solvelog/solvelog/issues
// @version      1.3.0
// @description  Send your Luogu practice page, Project Euler progress page or UOJ sign-in to the SolveLog Mac app.
// @description:zh-CN  把洛谷练习页、Project Euler 进度页或 UOJ 登录信息一键发送给 SolveLog。
// @license      GPL-3.0-or-later
// @match        https://www.luogu.com.cn/*
// @match        https://projecteuler.net/*
// @match        https://uoj.ac/*
// @grant        GM_cookie
// @grant        GM_setClipboard
// @run-at       document-idle
// @noframes
// ==/UserScript==

/*
 * SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
 *
 * Luogu and Project Euler: no cookie is read at all. On your Luogu practice page / PE progress page
 * the script copies the data that page already shows (Luogu embeds it as JSON); SolveLog parses it
 * locally and never contacts those sites. Luogu explicitly warns against giving cookies to tools.
 *
 * UOJ only shows submissions when you are signed in, and its session cookie is HttpOnly
 * (page scripts cannot read it). Tampermonkey's GM_cookie can,
 * once you allow it: Tampermonkey Dashboard → Settings → Config mode: Advanced →
 * Security → "Allow scripts to access cookies" → "All".
 *
 * The cookie is only put on your clipboard. Paste it into SolveLog (⌘⇧V); SolveLog stores it
 * in the macOS Keychain, clears the clipboard, and only ever sends it back to the same site.
 */
(function () {
  "use strict";

  const zh = /^zh/i.test(navigator.language || "");
  const T = zh ? {
    button: "复制到 SolveLog",
    title: "复制本站登录 Cookie，供 SolveLog 同步使用",
    noApi: "当前 Tampermonkey 不支持 GM_cookie，无法读取 HttpOnly Cookie。",
    none: "读取不到任何 Cookie。本站登录 Cookie 是 HttpOnly 的：请在 Tampermonkey 设置 →（配置模式：高级）→ 安全 →「允许脚本访问 Cookie」选择「全部」。",
    notSignedIn: (site, names) => `没有找到 ${site} 的登录 Cookie，请先登录。脚本拿到的 Cookie：${names}`,
    copied: site => `已复制 ${site} 登录信息。切换到 SolveLog 按 ⌘⇧V 导入。`,
    pageButton: "发送到 SolveLog",
    openProgress: "请先打开 Project Euler 的 Progress 页面（projecteuler.net/progress），再点这个按钮。",
    noSolved: "这个页面上没有找到已解决的题目，请确认已登录。",
    pageCopied: n => `已复制 ${n} 道已解决题目。切换到 SolveLog 按 ⌘⇧V 导入。`,
    openPractice: "请打开你自己的洛谷练习页（个人主页 → 练习），或只显示你自己的评测记录页（地址里带 ?user=你的uid），再点这个按钮。",
    recordsCopied: (n, page) => `已复制第 ${page} 页的 ${n} 条评测记录。切换到 SolveLog 按 ⌘⇧V 导入。`,
    notYours: "这一页里有别人的评测记录。请打开只显示你自己的评测记录页（地址里带 ?user=你的uid）。",
    practiceCopied: (a, b) => `已复制 ${a} 道已通过、${b} 道尝试过未通过的题目。切换到 SolveLog 按 ⌘⇧V 导入。`,
    reload: "页面数据和地址不一致（站内跳转过来的），请刷新本页后再点。",
  } : {
    button: "Copy to SolveLog",
    title: "Copy this site's sign-in cookie for the SolveLog app",
    noApi: "This Tampermonkey version has no GM_cookie, so HttpOnly cookies cannot be read.",
    none: "No cookies were returned. The sign-in cookie is HttpOnly: in Tampermonkey open Settings → Config mode: Advanced → Security → “Allow scripts to access cookies” and choose “All”.",
    notSignedIn: (site, names) => `No ${site} sign-in cookie found — please sign in first. Cookies seen: ${names}`,
    copied: site => `Copied your ${site} sign-in. Switch to SolveLog and press ⌘⇧V.`,
    pageButton: "Send to SolveLog",
    openProgress: "Open your Project Euler Progress page (projecteuler.net/progress) first, then click this button.",
    noSolved: "No solved problems found on this page — are you signed in?",
    pageCopied: n => `Copied ${n} solved problems. Switch to SolveLog and press ⌘⇧V.`,
    openPractice: "Open your own Luogu practice page (profile → 练习) or your own record list (评测记录 with ?user=<your uid>), then click this button.",
    recordsCopied: (n, page) => `Copied ${n} submissions from record page ${page}. Switch to SolveLog and press ⌘⇧V.`,
    notYours: "This page shows other people's submissions. Open the record list filtered to you (?user=<your uid>).",
    practiceCopied: (a, b) => `Copied ${a} solved and ${b} tried-but-unsolved problems. Switch to SolveLog and press ⌘⇧V.`,
    reload: "The page data does not match the address (you navigated inside Luogu) — reload this page and try again.",
  };

  // Per site: SolveLog platform id, which cookies to send, and how to tell that you are signed in.
  const SITES = {
    "www.luogu.com.cn": { oj: "luogu", label: "Luogu", page: true },
    "projecteuler.net": { oj: "projecteuler", label: "Project Euler", page: true },
    "uoj.ac": {
      oj: "uoj", label: "UOJ",
      pick: c => /^UOJSESSID$|^uoj_/.test(c.name),
      signedIn: cs => cs.some(c => c.name === "UOJSESSID" || c.name === "uoj_remember_token"),
    },
  };
  const site = SITES[location.hostname];
  if (!site) return;

  function toast(msg, ok) {
    const t = document.createElement("div");
    t.textContent = msg;
    Object.assign(t.style, {
      position: "fixed", right: "20px", bottom: "64px", zIndex: 2147483647, maxWidth: "340px",
      padding: "8px 12px", borderRadius: "8px", font: "13px/1.5 -apple-system, system-ui, sans-serif",
      color: "#fff", background: ok ? "#0f7b3f" : "#b42318", boxShadow: "0 4px 14px rgba(0,0,0,.2)",
    });
    document.body.appendChild(t);
    setTimeout(() => t.remove(), 9000);
  }

  // Luogu embeds the data of the page you are viewing as JSON in <script id="lentille-context">.
  // Two pages are supported: your practice page and your record list. Nothing else is requested.
  function copyLuogu() {
    let ctx;
    const read = () => { try { return JSON.parse(document.getElementById("lentille-context").textContent); } catch (e) { return null; } };
    const practice = location.pathname.match(/^\/user\/(\d+)\/practice/);
    if (practice) {
      ctx = read();
      const d = (ctx && ctx.data) || {};
      if (!Array.isArray(d.passed) || !d.user || String(d.user.uid) !== practice[1]) { toast(T.reload, false); return; }
      const slim = list => (list || []).map(p => ({ pid: p.pid, name: p.name, difficulty: p.difficulty, type: p.type }));
      const passed = slim(d.passed), submitted = slim(d.submitted);
      GM_setClipboard("solvelog-page:" + JSON.stringify({ v: 1, oj: "luogu", kind: "practice", uid: d.user.uid, name: d.user.name, passed, submitted }), "text");
      toast(T.practiceCopied(passed.length, submitted.length), true);
      return;
    }
    if (location.pathname.startsWith("/record/list")) {
      const q = new URLSearchParams(location.search);
      const uid = q.get("user");
      if (!uid || !/^\d+$/.test(uid)) { toast(T.notYours, false); return; }
      ctx = read();
      const recs = ctx && ctx.template === "record.list" && ctx.data && ctx.data.records;
      if (!recs || !Array.isArray(recs.result)) { toast(T.reload, false); return; }
      if (recs.result.some(r => !r.user || String(r.user.uid) !== uid)) { toast(T.notYours, false); return; }
      const page = parseInt(q.get("page") || "1", 10) || 1;
      const records = recs.result.map(r => ({
        id: r.id, status: r.status, score: r.score, time: r.time, memory: r.memory,
        sourceCodeLength: r.sourceCodeLength, submitTime: r.submitTime, language: r.language,
        contest: r.contest ? { id: r.contest.id, name: r.contest.name } : null,
        problem: r.problem ? { pid: r.problem.pid, name: r.problem.name, difficulty: r.problem.difficulty, type: r.problem.type } : null,
      }));
      GM_setClipboard("solvelog-page:" + JSON.stringify({ v: 1, oj: "luogu", kind: "records", uid: Number(uid), page, records }), "text");
      toast(T.recordsCopied(records.length, page), true);
      return;
    }
    toast(T.openPractice, false);
  }

  // Project Euler: copy the solved-problem table of the page you are viewing (no cookie, no requests).
  function copyPage() {
    if (site.oj === "luogu") { copyLuogu(); return; }
    if (!location.pathname.startsWith("/progress")) { toast(T.openProgress, false); return; }
    const cells = [...document.querySelectorAll("td.problem_solved")];
    const ids = new Set(cells.map(td => { const a = td.querySelector("a"); return a && a.getAttribute("href"); }));
    if (!cells.length) { toast(T.noSolved, false); return; }
    const heads = [...document.querySelectorAll("h2, h3, h4")].map(h => h.innerText.trim());
    const i = heads.findIndex(h => /Solved \d+ out of/.test(h));
    const handle = i > 0 ? heads[i - 1] : null;
    const html = cells.map(td => td.outerHTML).join("\n");
    GM_setClipboard("solvelog-page:" + JSON.stringify({ v: 1, oj: site.oj, handle, html }), "text");
    toast(T.pageCopied(ids.size), true);
  }

  function copyCookie() {
    if (typeof GM_cookie === "undefined" || !GM_cookie.list) { toast(T.noApi, false); return; }
    // Query by URL (covers __Host- cookies) and by domain, then merge.
    const queries = [{ url: location.origin + "/" }, { domain: location.hostname }];
    const found = new Map(), errors = [];
    let pending = queries.length;
    queries.forEach(q => GM_cookie.list(q, (cookies, error) => {
      if (error) errors.push(String(error));
      (cookies || []).forEach(c => found.set(c.name + "@" + (c.domain || ""), c));
      if (--pending === 0) finish([...found.values()], errors);
    }));
  }

  function finish(cookies, errors) {
    if (!cookies.length) { toast(T.none + (errors.length ? " (" + errors.join("; ") + ")" : ""), false); return; }
    const names = [...new Set(cookies.map(c => c.name + (c.httpOnly ? " (HttpOnly)" : "")))].join(", ");
    const picked = cookies.filter(site.pick);
    if (!site.signedIn(picked)) { toast(T.notSignedIn(site.label, names), false); return; }
    const seen = new Set();
    const cookie = picked.filter(c => !seen.has(c.name) && seen.add(c.name)).map(c => c.name + "=" + c.value).join("; ");
    GM_setClipboard("solvelog-cookie:" + JSON.stringify({ v: 1, oj: site.oj, cookie }), "text");
    toast(T.copied(site.label), true);
  }

  const btn = document.createElement("button");
  btn.textContent = site.page ? T.pageButton : T.button;
  btn.title = T.title;
  Object.assign(btn.style, {
    position: "fixed", right: "20px", bottom: "20px", zIndex: 2147483647, cursor: "pointer",
    padding: "6px 12px", border: "none", borderRadius: "8px", font: "600 13px -apple-system, system-ui, sans-serif",
    color: "#fff", background: "#2a78d6", boxShadow: "0 2px 8px rgba(0,0,0,.2)", opacity: "0.85",
  });
  btn.addEventListener("mouseenter", () => (btn.style.opacity = "1"));
  btn.addEventListener("mouseleave", () => (btn.style.opacity = "0.85"));
  btn.addEventListener("click", site.page ? copyPage : copyCookie);
  document.body.appendChild(btn);
})();

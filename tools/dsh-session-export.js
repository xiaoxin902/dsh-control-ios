#!/usr/bin/env node22
// 把 dsh 会话的 session.v4.jsonl 转成 Markdown。
//
//   node22 dsh-session-export.js            # 最新一个会话
//   node22 dsh-session-export.js <会话目录或 id> [输出目录]
//
// 输出目录默认 /var/mobile/Documents/dsh-backup/exports，
// 文件名 <会话id>-<时间>.md，并额外写一份 latest.md。
const fs = require('fs');
const path = require('path');

const HOME = '/var/mobile';
const SESSIONS = path.join(HOME, '.dsh', 'sessions');
const OUT_DEFAULT = path.join(HOME, 'Documents', 'dsh-backup', 'exports');

function listSessions(dir) {
  const out = [];
  let workspaces = [];
  try { workspaces = fs.readdirSync(dir); } catch { return out; }
  for (const ws of workspaces) {
    const wsDir = path.join(dir, ws);
    let entries = [];
    try { entries = fs.readdirSync(wsDir); } catch { continue; }
    for (const name of entries) {
      const file = path.join(wsDir, name, 'session.v4.jsonl');
      try {
        const st = fs.statSync(file);
        out.push({ id: name, file, mtime: st.mtimeMs, workspace: ws });
      } catch {}
    }
  }
  out.sort((a, b) => b.mtime - a.mtime);
  return out;
}

function findSession(arg) {
  const all = listSessions(SESSIONS);
  if (!arg) {
    if (!all.length) throw new Error('没有找到任何会话');
    return all[0];
  }
  const hit = all.find((s) => s.id === arg || s.id === 'session-' + arg || s.file.includes(arg));
  if (!hit) throw new Error('找不到会话: ' + arg);
  return hit;
}

function stamp(ms) {
  const d = new Date(ms);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

function textOf(parts) {
  return (parts || [])
    .filter((p) => p && (p.type === 'text' || p.type === 'input-text') && typeof p.text === 'string')
    .map((p) => p.text)
    .join('\n')
    .trim();
}

function filesOf(parts) {
  return (parts || [])
    .filter((p) => p && p.type === 'file' && p.attachment && p.attachment.name)
    .map((p) => p.attachment.name);
}

function clip(s, n) {
  const t = String(s || '').replace(/\s+/g, ' ').trim();
  return t.length > n ? t.slice(0, n) + '…' : t;
}

function convert(file) {
  const lines = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean);
  const md = [];
  let meta = null;
  const pendingUser = [];

  for (const line of lines) {
    let ev;
    try { ev = JSON.parse(line); } catch { continue; }
    if (ev.type === 'session') { meta = ev; continue; }

    if (ev.type === 'agent/inbox/spliced') {
      for (const item of ev.data?.inserted || []) {
        const t = textOf(item.content);
        const f = filesOf(item.content);
        if (t || f.length) pendingUser.push({ time: ev.time, text: t, files: f });
      }
      continue;
    }

    if (ev.type === 'assistant/message') {
      if (pendingUser.length) {
        for (const u of pendingUser) {
          md.push(`\n## 👤 用户 · ${stamp(u.time)}\n`);
          if (u.files.length) md.push(u.files.map((n) => `- 附件：\`${n}\``).join('\n') + '\n');
          if (u.text) md.push(u.text + '\n');
        }
        pendingUser.length = 0;
      }
      const content = ev.data?.message?.content || [];
      const reply = textOf(content);
      const reasoning = content.filter((c) => c && c.type === 'reasoning' && c.text).map((c) => c.text);
      const calls = content.filter((c) => c && c.type === 'tool-call');
      if (!reply && !reasoning.length && !calls.length) continue;
      md.push(`\n## 🤖 助手 · ${stamp(ev.time)}\n`);
      if (reasoning.length) {
        md.push('<details><summary>思考过程</summary>\n');
        for (const r of reasoning) md.push('\n' + r + '\n');
        md.push('\n</details>\n');
      }
      if (calls.length) {
        md.push('\n**调用工具**\n');
        for (const c of calls) md.push(`- \`${c.name}\` — ${clip(c.arguments, 160)}`);
        md.push('');
      }
      if (reply) md.push('\n' + reply + '\n');
    }
  }

  for (const u of pendingUser) {
    md.push(`\n## 👤 用户 · ${stamp(u.time)}\n`);
    if (u.files.length) md.push(u.files.map((n) => `- 附件：\`${n}\``).join('\n') + '\n');
    if (u.text) md.push(u.text + '\n');
  }

  const head = [];
  head.push(`# dsh 会话导出`);
  head.push('');
  head.push(`- 会话：\`${meta?.id || path.basename(path.dirname(file))}\``);
  if (meta?.cwd) head.push(`- 工作目录：\`${meta.cwd}\``);
  if (meta?.createdAt) head.push(`- 创建：${stamp(meta.createdAt)}`);
  head.push(`- 导出：${stamp(Date.now())}`);
  head.push('');
  return head.join('\n') + md.join('\n');
}

function main() {
  const target = findSession(process.argv[2]);
  const outDir = process.argv[3] || OUT_DEFAULT;
  fs.mkdirSync(outDir, { recursive: true });
  const body = convert(target.file);
  const name = `${target.id}-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, '')}.md`;
  const out = path.join(outDir, name);
  fs.writeFileSync(out, body);
  fs.writeFileSync(path.join(outDir, 'latest.md'), body);
  console.log(out);
  console.log(`${(body.length / 1024).toFixed(1)} KB，${body.split('\n').length} 行`);
}

main();

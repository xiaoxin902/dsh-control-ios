#!/usr/bin/env node22
// 插件安装助手：由控制守护进程以 mobile 身份调用。
//
//   node22 dsh-plugin.js <请求文件> <动作>
//
// 动作：list / install / remove。请求文件与控制守护进程共用一份 JSON：
//   {"command":"plugin-install","target":"/var/mobile/Documents/dsh-plugins/x.tgz"}
// 结果以 JSON 打到 stdout，守护进程原样写进 .dshcontrol-result。
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const HOME = '/var/mobile';
const PROFILE = path.join(HOME, '.dsh', 'profiles', 'web');
const PNPM = path.join(HOME, '.tools', 'bin', 'pnpm');
const TGZ_DIRS = [
  path.join(HOME, 'Documents', 'dsh-plugins'),
  path.join(HOME, '.tools', 'pkgs'),
];

function readRequest(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return {};
  }
}

function readProfile() {
  try {
    return JSON.parse(fs.readFileSync(path.join(PROFILE, 'package.json'), 'utf8'));
  } catch {
    return { dependencies: {} };
  }
}

/// link: 开头的依赖是 dsh 自己的包，不算用户插件。
function installedPlugins() {
  const deps = readProfile().dependencies || {};
  return Object.keys(deps)
    .filter((name) => !String(deps[name]).startsWith('link:'))
    .sort()
    .map((name) => {
      let version = String(deps[name]);
      let title = name;
      try {
        const pkg = JSON.parse(fs.readFileSync(path.join(PROFILE, 'node_modules', name, 'package.json'), 'utf8'));
        version = pkg.version || version;
        title = pkg.dsh && pkg.dsh.name ? pkg.dsh.name : name;
      } catch {}
      return { name, version, title };
    });
}

function availablePackages() {
  const out = [];
  for (const dir of TGZ_DIRS) {
    let entries = [];
    try {
      entries = fs.readdirSync(dir);
    } catch {
      continue;
    }
    for (const name of entries) {
      if (!name.endsWith('.tgz')) {
        continue;
      }
      const full = path.join(dir, name);
      try {
        const st = fs.statSync(full);
        if (st.isFile()) {
          out.push({ path: full, name, size: st.size });
        }
      } catch {}
    }
  }
  const seen = new Map();
  for (const item of out) {
    if (!seen.has(item.name)) {
      seen.set(item.name, item);
    }
  }
  return [...seen.values()].sort((a, b) => b.name.localeCompare(a.name));
}

function pnpm(args) {
  const result = spawnSync(PNPM, args, {
    cwd: PROFILE,
    env: {
      HOME,
      PATH: [
        path.join(HOME, '.tools', 'bin'),
        '/var/jb/usr/local/bin',
        '/var/jb/usr/bin',
        '/usr/bin',
        '/bin',
      ].join(':'),
      TMPDIR: '/tmp',
    },
    encoding: 'utf8',
    timeout: 240000,
  });
  const output = ((result.stdout || '') + (result.stderr || '')).trim().split('\n').slice(-6).join('\n');
  return { ok: result.status === 0, status: result.status, output };
}

function main() {
  const [requestFile, actionArg] = process.argv.slice(2);
  const request = requestFile ? readRequest(requestFile) : {};
  const action = actionArg || 'list';
  const target = typeof request.target === 'string' ? request.target.trim() : '';

  if (action === 'list') {
    const result = {
      ok: true,
      action: 'list',
      installed: installedPlugins(),
      available: availablePackages(),
      profile: PROFILE,
    };
    process.stdout.write(JSON.stringify(result));
    return;
  }

  if (action === 'install') {
    if (!target) {
      process.stdout.write(JSON.stringify({ ok: false, message: '没有给出要安装的包名或文件路径' }));
      return;
    }
    let spec = target;
    if (target.startsWith('/') || target.startsWith('~/')) {
      const full = target.startsWith('~/') ? path.join(HOME, target.slice(2)) : target;
      if (!fs.existsSync(full)) {
        process.stdout.write(JSON.stringify({ ok: false, message: '找不到文件：' + full }));
        return;
      }
      spec = full;
    }
    const started = Date.now();
    const run = pnpm(['add', spec]);
    const result = {
      ok: run.ok,
      action: 'install',
      target: spec,
      message: run.ok ? '已安装' : '安装失败',
      seconds: Math.round((Date.now() - started) / 1000),
      output: run.output,
      installed: installedPlugins(),
    };
    process.stdout.write(JSON.stringify(result));
    return;
  }

  if (action === 'remove') {
    if (!target) {
      process.stdout.write(JSON.stringify({ ok: false, message: '没有给出要移除的包名' }));
      return;
    }
    const run = pnpm(['remove', target]);
    process.stdout.write(JSON.stringify({
      ok: run.ok,
      action: 'remove',
      target,
      message: run.ok ? '已移除' : '移除失败',
      output: run.output,
      installed: installedPlugins(),
    }));
    return;
  }

  process.stdout.write(JSON.stringify({ ok: false, message: '未知动作：' + action }));
}

main();

'use strict';

// class_score 同步服务 · 管理后台
//
// 无框架、无构建步骤：所有逻辑都在这一个文件里，浏览器直接执行。
// 有两条纪律必须一直守：
//   1. 只能用 textContent 写值——数据来自已配对设备，等同不可信输入，
//      拼进 innerHTML 等于把 XSS 权限交给任何能配对的人；
//   2. 未登录时不渲染任何数据（见 renderLogin / showApp 的调用关系）。

const KEY = 'class_score.admin.session';

const state = {
  session: localStorage.getItem(KEY) || '',
  tab: 'overview',
  table: 'students',
  offset: 0,
  limit: 50,
  q: '',
  deleted: false,
  total: 0,
  selectedUid: null,
  columns: [],
  editable: [],
};

const $ = (id) => document.getElementById(id);

// ---- HTTP ----

class ApiError extends Error {
  constructor(status, body) {
    super('HTTP ' + status + (body && body.error ? '：' + body.error : ''));
    this.status = status;
  }
}

async function api(method, path, body) {
  const headers = {};
  if (state.session) headers['authorization'] = 'Bearer ' + state.session;
  if (body !== undefined) headers['content-type'] = 'application/json';
  const res = await fetch(path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let json = null;
  try { json = await res.json(); } catch (e) { json = null; }
  if (res.status === 401) {
    // 会话过期：退回登录框，绝不把半截数据留在屏幕上。
    signOut(false);
    throw new ApiError(401, json);
  }
  if (!res.ok) throw new ApiError(res.status, json);
  return json;
}

// ---- 界面骨架 ----

function showApp(on) {
  $('login').classList.toggle('hidden', on);
  $('app').classList.toggle('hidden', !on);
  $('btn-logout').classList.toggle('hidden', !on);
}

function renderLogin() {
  showApp(false);
  $('app').innerHTML = '';
}

function signOut(notify) {
  if (notify && state.session) {
    api('POST', '/admin/api/logout').catch(() => {});
  }
  state.session = '';
  localStorage.removeItem(KEY);
  showApp(false);
  $('login-error').textContent = '';
  $('status').textContent = '';
  $('login-token').value = '';
  // 重新载入，确保上一会话的任何 DOM 都不残留
  if (notify) location.reload();
}

function setStatus(text) { $('status').textContent = text || ''; }

// ---- 登录 ----

async function doLogin(ev) {
  ev.preventDefault();
  const token = $('login-token').value.trim();
  if (!token) return;
  $('login-error').textContent = '';
  try {
    const out = await api('POST', '/admin/api/login', { token });
    state.session = out.session;
    localStorage.setItem(KEY, out.session);
    await enterApp();
  } catch (e) {
    $('login-error').textContent =
      e.status === 429 ? '尝试次数过多，请稍后再试'
      : e.status === 401 ? '令牌不正确'
      : String(e.message || e);
  }
}

async function enterApp() {
  showApp(true);
  await refreshOverview();
  await refreshDevices();
  switchTab(state.tab);
}

// ---- 概览 ----

async function refreshOverview() {
  const d = await api('GET', '/admin/api/overview');
  setStatus('协议 v' + d.protocol + ' · 最大 seq ' + d.max_seq);
  const cards = [
    ['已配对设备', d.device_count],
    ['事件总数', d.event_count],
    ['最大 seq', d.max_seq],
    ['配对码', d.pairing_code || '（无）'],
  ];
  const box = $('overview-cards');
  box.textContent = '';
  for (const [k, v] of cards) {
    const el = document.createElement('div');
    el.className = 'card';
    const kk = document.createElement('div'); kk.className = 'k'; kk.textContent = k;
    const vv = document.createElement('div'); vv.className = 'v'; vv.textContent = String(v);
    el.append(kk, vv);
    box.append(el);
  }
  const body = $('overview-tables').querySelector('tbody');
  body.textContent = '';
  for (const [name, counts] of Object.entries(d.tables)) {
    const tr = document.createElement('tr');
    for (const text of [name, counts.live, counts.deleted]) {
      const td = document.createElement('td');
      td.textContent = String(text);
      tr.append(td);
    }
    body.append(tr);
  }
}

// ---- 设备 ----

async function refreshDevices() {
  const d = await api('GET', '/admin/api/devices');
  const p = await api('GET', '/admin/api/pairing');
  $('pairing-info').textContent = p.code
    ? '当前配对码 ' + p.code + '（至 ' + fmt(p.expires_at) + '）'
    : '当前没有可用配对码';

  const body = $('devices-table').querySelector('tbody');
  body.textContent = '';
  if (!d.devices.length) {
    const tr = document.createElement('tr');
    const td = document.createElement('td');
    td.colSpan = 6;
    td.className = 'hint';
    td.textContent = '还没有设备配对过。点上面的「生成新配对码」，在 App 里填入即可。';
    tr.append(td); body.append(tr);
    return;
  }
  for (const dev of d.devices) {
    const tr = document.createElement('tr');
    for (const text of [dev.id, dev.name || '（未命名）', fmt(dev.created_at),
                        dev.last_seen_at ? fmt(dev.last_seen_at) : '从未', dev.events]) {
      const td = document.createElement('td');
      td.textContent = String(text);
      tr.append(td);
    }
    const td = document.createElement('td');
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'danger';
    btn.textContent = '撤销';
    btn.onclick = () => revokeDevice(dev);
    td.append(btn);
    tr.append(td);
    body.append(tr);
  }
}

async function revokeDevice(dev) {
  const ok = confirm(
    '撤销设备「' + (dev.name || dev.id) + '」？\n\n' +
    '该设备下次同步会收到 401，App 会显示「需要重新配对」。\n' +
    '设备上的本地数据不受影响，重新配对后即可继续同步。'
  );
  if (!ok) return;
  await api('DELETE', '/admin/api/devices/' + encodeURIComponent(dev.id));
  await refreshDevices();
  await refreshOverview();
}

async function newPairingCode() {
  await api('POST', '/admin/api/pairing');
  await refreshDevices();
}

// ---- 数据 ----

async function loadTables() {
  // 表清单来自服务端响应里的 columns/editable；表名集合在 overview 里更权威，
  // 但为了少一次请求，这里用固定顺序（与 syncTableSpecs 一致）。
  const sel = $('table-select');
  if (sel.options.length) return;
  const names = ['groups', 'students', 'score_items', 'score_records',
                 'course_schedule', 'schedule_adjustment', 'app_settings'];
  for (const name of names) {
    const opt = document.createElement('option');
    opt.value = name;
    opt.textContent = name;
    sel.append(opt);
  }
  sel.value = state.table;
}

async function loadRows() {
  const params = new URLSearchParams({
    offset: String(state.offset),
    limit: String(state.limit),
  });
  if (state.q) params.set('q', state.q);
  if (state.deleted) params.set('deleted', '1');

  const d = await api('GET', '/admin/api/table/' + encodeURIComponent(state.table) +
    '?' + params.toString());
  state.total = d.total;
  state.columns = d.columns;
  state.editable = d.editable;

  $('table-meta').textContent =
    state.table + ' · 共 ' + d.total + ' 行 · 可编辑列：' + d.editable.join('、');

  const head = $('rows-table').querySelector('thead');
  head.textContent = '';
  const htr = document.createElement('tr');
  for (const name of ['uid', 'op', 'rev', ...d.columns]) {
    const th = document.createElement('th');
    th.textContent = name;
    htr.append(th);
  }
  head.append(htr);

  const body = $('rows-table').querySelector('tbody');
  body.textContent = '';
  if (!d.rows.length) {
    const tr = document.createElement('tr');
    const td = document.createElement('td');
    td.colSpan = 3 + d.columns.length;
    td.className = 'hint';
    td.textContent = '没有匹配的行。';
    tr.append(td);
    body.append(tr);
  }
  for (const row of d.rows) {
    const tr = document.createElement('tr');
    tr.className = 'selectable' + (row.op === 'delete' ? ' deleted' : '');
    if (row.uid === state.selectedUid) tr.classList.add('selected');
    for (const text of [row.uid, row.op, row.rev,
                        ...d.columns.map((c) => valueText(row.data ? row.data[c] : undefined))]) {
      const td = document.createElement('td');
      td.textContent = String(text);
      tr.append(td);
    }
    tr.onclick = () => selectRow(row, tr);
    body.append(tr);
  }

  const from = d.total === 0 ? 0 : state.offset + 1;
  const to = Math.min(state.offset + d.rows.length, d.total);
  $('page-info').textContent = from + '–' + to + ' / ' + d.total;
  $('btn-prev').disabled = state.offset <= 0;
  $('btn-next').disabled = state.offset + state.limit >= d.total;

  if (state.selectedUid) {
    const hit = d.rows.find((r) => r.uid === state.selectedUid);
    if (hit) renderEditor(hit);
  }
}

function valueText(v) {
  if (v === null || v === undefined) return '';
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}

function selectRow(row, tr) {
  state.selectedUid = row.uid;
  for (const el of $('rows-table').querySelectorAll('tbody tr')) {
    el.classList.remove('selected');
  }
  tr.classList.add('selected');
  renderEditor(row);
}

function renderEditor(row) {
  const box = $('editor');
  box.textContent = '';

  const h = document.createElement('h4');
  h.textContent = '行详情';
  box.append(h);

  const uid = document.createElement('div');
  uid.className = 'mono uid';
  uid.textContent = row.uid;
  box.append(uid);

  const meta = document.createElement('div');
  meta.className = 'mono';
  meta.textContent = 'op=' + row.op + ' rev=' + row.rev + ' by ' + row.rev_device;
  box.append(meta);

  if (row.op === 'delete') {
    const p = document.createElement('p');
    p.className = 'hint';
    p.textContent = '这一行已删除（墓碑）。恢复请在 App 里操作——服务端造墓碑/复活会与回收站语义冲突。';
    box.append(p);
  } else {
    const fs = document.createElement('fieldset');
    const lg = document.createElement('legend');
    lg.textContent = '编辑（可改的列）';
    fs.append(lg);
    for (const col of state.editable) {
      fs.append(fieldFor(col, row.data ? row.data[col] : undefined));
    }
    const save = document.createElement('button');
    save.type = 'button';
    save.textContent = '保存';
    save.onclick = () => saveEdit(row);
    fs.append(save);
    box.append(fs);
  }

  const rawTitle = document.createElement('h4');
  rawTitle.textContent = '原始 JSON';
  const pre = document.createElement('pre');
  pre.textContent = JSON.stringify(row.data, null, 2);
  box.append(rawTitle, pre);
}

function fieldFor(col, value) {
  const label = document.createElement('label');
  const span = document.createElement('span');
  span.textContent = col + (value === null || value === undefined ? '（当前为空）' : '');
  label.append(span);

  let input;
  if (typeof value === 'number') {
    input = document.createElement('input');
    input.type = 'number';
    input.step = Number.isInteger(value) ? '1' : 'any';
    input.value = String(value);
    input.dataset.kind = Number.isInteger(value) ? 'int' : 'num';
  } else if (typeof value === 'boolean') {
    input = document.createElement('select');
    for (const [v, t] of [['true', '是'], ['false', '否']]) {
      const o = document.createElement('option');
      o.value = v; o.textContent = t;
      input.append(o);
    }
    input.value = value ? 'true' : 'false';
    input.dataset.kind = 'bool';
  } else {
    input = document.createElement('input');
    input.type = 'text';
    input.value = value === null || value === undefined ? '' : String(value);
    input.dataset.kind = 'str';
  }
  input.dataset.col = col;
  label.append(input);
  return label;
}

async function saveEdit(row) {
  const patch = {};
  let bad = null;
  for (const input of $('editor').querySelectorAll('[data-col]')) {
    const col = input.dataset.col;
    const kind = input.dataset.kind;
    const raw = input.value;
    let next;
    if (kind === 'int') next = parseInt(raw, 10);
    else if (kind === 'num') next = parseFloat(raw);
    else if (kind === 'bool') next = raw === 'true';
    else next = raw;
    if ((kind === 'int' || kind === 'num') && Number.isNaN(next)) {
      bad = col + ' 需要数字';
      break;
    }
    if (JSON.stringify(next) !== JSON.stringify(row.data ? row.data[col] : null)) {
      patch[col] = next;
    }
  }
  if (bad) { alert(bad); return; }
  if (!Object.keys(patch).length) { alert('没有改动'); return; }

  try {
    await api('PATCH', '/admin/api/table/' + encodeURIComponent(state.table) +
      '/' + encodeURIComponent(row.uid), { data: patch });
    await loadRows();
    await refreshOverview();
  } catch (e) {
    alert('保存失败：' + (e.message || e));
  }
}

// ---- 审计 ----

async function refreshAudit() {
  const d = await api('GET', '/admin/api/audit');
  const body = $('audit-table').querySelector('tbody');
  body.textContent = '';
  if (!d.entries.length) {
    const tr = document.createElement('tr');
    const td = document.createElement('td');
    td.colSpan = 6; td.className = 'hint';
    td.textContent = '还没有管理操作。';
    tr.append(td); body.append(tr);
    return;
  }
  for (const e of d.entries) {
    const tr = document.createElement('tr');
    const cells = [
      fmt(e.ts), e.action, e.table || '', e.uid || '',
      diffText(e.before, e.after), e.source_ip || '',
    ];
    for (const text of cells) {
      const td = document.createElement('td');
      td.textContent = String(text);
      tr.append(td);
    }
    body.append(tr);
  }
}

function diffText(before, after) {
  if (!before && !after) return '';
  const keys = new Set([...Object.keys(before || {}), ...Object.keys(after || {})]);
  return [...keys].map((k) =>
    k + ': ' + valueText(before ? before[k] : undefined) +
    ' → ' + valueText(after ? after[k] : undefined)).join('；');
}

// ---- 工具 ----

function fmt(text) {
  if (!text) return '';
  const d = new Date(text);
  if (Number.isNaN(d.getTime())) return String(text);
  const pad = (n) => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
    ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
}

function switchTab(name) {
  state.tab = name;
  for (const btn of document.querySelectorAll('.tab')) {
    btn.classList.toggle('active', btn.dataset.tab === name);
  }
  for (const id of ['overview', 'devices', 'data', 'audit']) {
    $('tab-' + id).classList.toggle('hidden', id !== name);
  }
  if (name === 'overview') refreshOverview().catch(reportError);
  if (name === 'devices') refreshDevices().catch(reportError);
  if (name === 'data') { loadTables().then(loadRows).catch(reportError); }
  if (name === 'audit') refreshAudit().catch(reportError);
}

function reportError(e) {
  if (e && e.status === 401) return;
  setStatus('出错了：' + (e && e.message ? e.message : e));
}

// ---- 启动 ----

window.addEventListener('DOMContentLoaded', () => {
  $('login-form').addEventListener('submit', doLogin);
  $('btn-logout').addEventListener('click', () => signOut(true));
  $('btn-new-code').addEventListener('click', () => newPairingCode().catch(reportError));
  $('btn-reload').addEventListener('click', () => {
    state.q = $('q').value.trim();
    state.deleted = $('show-deleted').checked;
    state.offset = 0;
    loadRows().catch(reportError);
  });
  $('q').addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter') $('btn-reload').click();
  });
  $('table-select').addEventListener('change', () => {
    state.table = $('table-select').value;
    state.offset = 0;
    state.selectedUid = null;
    $('editor').textContent = '从左侧选一行查看详情。';
    loadRows().catch(reportError);
  });
  $('btn-prev').addEventListener('click', () => {
    state.offset = Math.max(0, state.offset - state.limit);
    loadRows().catch(reportError);
  });
  $('btn-next').addEventListener('click', () => {
    state.offset += state.limit;
    loadRows().catch(reportError);
  });
  for (const btn of document.querySelectorAll('.tab')) {
    btn.addEventListener('click', () => switchTab(btn.dataset.tab));
  }

  if (state.session) {
    enterApp().catch(() => signOut(false));
  } else {
    showApp(false);
  }
});

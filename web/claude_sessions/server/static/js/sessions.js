import { api } from './api.js';
import { $, escapeHtml, isContextMenuKey, isMac, onArrowKeys, selectRow, spans } from './dom.js';
import { baseName, dateTime, highlightMatches, isoDay, plural, repoOf, shellQuote } from './format.js';
import { closeMenu, openMenu } from './menu.js';
import { state } from './state.js';
import { report, showCount, subtitle } from './status.js';

let latestSearch = 0;

function searchParams() {
  const params = new URLSearchParams();
  const filters = [
    ['q', $('q').value],
    ['role', $('role').value],
    ['branch', $('branch').value],
    ['sort', $('sort').value],
    ['project', state.project],
  ];
  for (const [key, value] of filters) if (value) params.set(key, value);
  if (state.daysBack !== '') {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const from = new Date(today - state.daysBack * 864e5);
    params.set('since', isoDay(from));
    params.set('until', isoDay(state.daysBack === '1' ? from : today));
  }
  return params;
}

export async function runSearch() {
  const search = ++latestSearch;
  try {
    const result = await api(`/api/query?${searchParams()}`);
    if (search !== latestSearch) return;
    state.sessions = result.rows;
    state.facets.total = result.total;
    renderSessions();
    showCount();
  } catch (error) {
    report(error);
  }
}

function sessionRow(session, tabStop) {
  const repo = repoOf(session.project);
  const details = [
    repo !== state.project && baseName(repo),
    dateTime(session.modified),
    plural(session.turns, 'message'),
    session.branch,
    session.hits && plural(session.hits, 'mention'),
  ];
  return `<div class="row" role="option" data-id="${escapeHtml(session.id)}" aria-selected="${session.id === state.selected}" tabindex="${session.id === tabStop ? 0 : -1}">
<div class="t">${escapeHtml(session.title)}</div><div class="id">${escapeHtml(session.id)}</div>
<div class="sub">${spans(details)}</div>
${session.snip ? `<div class="snip">${highlightMatches(session.snip)}</div>` : ''}</div>`;
}

function renderSessions() {
  if (!state.sessions.some((session) => session.id === state.selected)) state.selected = null;
  const tabStop = state.selected ?? state.sessions[0]?.id;
  $('list').innerHTML = state.sessions.length
    ? state.sessions.map((session) => sessionRow(session, tabStop)).join('')
    : '<p class="empty">No sessions match. Try fewer words or a wider time range.</p>';
}

function pickSession(id, focus) {
  state.selected = id;
  selectRow($('list'), id, focus);
}

async function copyText(id, text, note) {
  try {
    await navigator.clipboard.writeText(text);
  } catch (error) {
    report(error);
    return;
  }
  subtitle(note, { flash: true });
  const cell = $('list').querySelector(`.row[data-id="${CSS.escape(id)}"] .id`);
  if (!cell) return;
  cell.textContent = 'Copied to clipboard';
  cell.classList.add('copied');
  setTimeout(() => {
    cell.textContent = id;
    cell.classList.remove('copied');
  }, 1400);
}

export const copySessionId = (id) => copyText(id, id, 'Copied session id');

function copyResumeCommand(id) {
  const session = state.sessions.find((candidate) => candidate.id === id);
  copyText(id, `cd ${shellQuote(session.project || '.')} && claude --resume ${id}`, 'Copied resume command');
}

const revealTranscript = (id) => api('/api/session/reveal', { id }).catch(report);

const sessionMenu = (id) => [
  { label: 'Copy Session ID', key: isMac ? '⌘C' : 'Ctrl+C', run: () => copySessionId(id) },
  { label: 'Copy Resume Command', run: () => copyResumeCommand(id) },
  null,
  { label: isMac ? 'Show Transcript in Finder' : 'Open Transcript Folder', run: () => revealTranscript(id) },
];

export function initSessions() {
  const list = $('list');
  list.addEventListener('click', (event) => {
    const row = event.target.closest('.row');
    if (row) pickSession(row.dataset.id);
  });
  list.addEventListener('dblclick', (event) => {
    const row = event.target.closest('.row');
    if (row) copySessionId(row.dataset.id);
  });
  list.addEventListener('contextmenu', (event) => {
    const row = event.target.closest('.row');
    if (!row) return;
    event.preventDefault();
    pickSession(row.dataset.id);
    openMenu(event.clientX, event.clientY, sessionMenu(row.dataset.id));
  });
  list.addEventListener('keydown', (event) => {
    const row = event.target.closest('.row');
    if (!row) return;
    if (event.key === 'Enter') copySessionId(row.dataset.id);
    if (isContextMenuKey(event)) {
      event.preventDefault();
      pickSession(row.dataset.id);
      const box = row.getBoundingClientRect();
      openMenu(box.left + 24, box.bottom - 6, sessionMenu(row.dataset.id));
    }
  });
  list.addEventListener('scroll', closeMenu);
  onArrowKeys(list, pickSession);
}

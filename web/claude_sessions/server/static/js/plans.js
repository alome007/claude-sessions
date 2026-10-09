import { api } from './api.js';
import { $, commandKey, escapeHtml, onArrowKeys, selectRow, spans } from './dom.js';
import { baseName, date, dateTime } from './format.js';
import { renderMarkdown } from './markdown.js';
import { state } from './state.js';
import { report, showCount } from './status.js';

const STATUS_LABELS = { active: 'Active', completed: 'Completed' };

let progressTimer;

export const planHash = (id) => `#plans/${encodeURIComponent(id)}`;

const currentPlan = () => state.plans.find((plan) => plan.id === state.open);

export const hasUnsavedEdits = () =>
  state.editing && $('editor').value !== currentPlan()?.body.replace(/\r\n/g, '\n');

const mayLeaveEdits = () => !hasUnsavedEdits() || confirm('Discard your changes to this plan?');

export function shownPlans() {
  const needle = $('q').value.trim().toLowerCase();
  return state.plans.filter((plan) =>
    (state.project ? plan.project === state.project : !state.facets.archived.includes(plan.project))
    && (!needle || [plan.title, plan.body, ...plan.tags].some((text) => text.toLowerCase().includes(needle))));
}

function planRow(plan, tabStop) {
  const read = Number(plan.progress) || 0;
  const details = [baseName(plan.project) || 'Unassigned', STATUS_LABELS[plan.status], plan.tags.join(', '), date(plan.modified)];
  return `<div class="row plan" role="option" data-id="${escapeHtml(plan.id)}" aria-selected="${plan.id === state.open}" tabindex="${plan.id === tabStop ? 0 : -1}">
<div class="t">${escapeHtml(plan.title)}</div>${plan.pinned ? '<span class="pin" title="Pinned"></span>' : '<span></span>'}
<div class="sub">${spans(details)}</div>
${read > 0 && read < 1 ? `<div class="prog"><i style="width:${(read * 100).toFixed(1)}%"></i></div>` : ''}</div>`;
}

export function renderPlans() {
  if (!state.plans) return;
  const shown = shownPlans();
  const list = $('planList');
  const focused = list.contains(document.activeElement) && document.activeElement.dataset.id;
  const tabStop = shown.some((plan) => plan.id === state.open) ? state.open : shown[0]?.id;
  list.innerHTML = shown.length
    ? shown.map((plan) => planRow(plan, tabStop)).join('')
    : `<p class="empty">${state.plans.length ? 'No plans match. Try fewer words or another project.' : 'No plans yet. Plans you make in Claude Code show up here.'}</p>`;
  if (focused) list.querySelector(`.row[data-id="${CSS.escape(focused)}"]`)?.focus({ preventScroll: true });
  showCount();
}

export async function loadPlans() {
  if (!state.plans) $('planList').innerHTML = '<p class="empty">Reading plans...</p>';
  try {
    state.plans = (await api('/api/plans')).plans;
  } catch (error) {
    report(error);
    return;
  }
  renderPlans();
  const linked = !state.open && state.plans.find((plan) => location.hash === planHash(plan.id));
  if (linked) openPlan(linked.id);
  else if (state.open && !state.editing) showPlan(state.open);
}

function setEditing(on) {
  state.editing = on;
  $('edit').textContent = on ? 'Save' : 'Edit';
  $('doc').hidden = on;
  $('editor').hidden = !on;
}

function openPlan(id, focus) {
  if (id !== state.open && !mayLeaveEdits()) return;
  state.open = id;
  setEditing(false);
  selectRow($('planList'), id, focus);
  $('plans').dataset.open = '';
  history.replaceState(null, '', planHash(id));
  showPlan(id);
}

function closePlan() {
  state.open = null;
  setEditing(false);
  history.replaceState(null, '', '#plans');
  $('readerEmpty').hidden = false;
  $('readerBody').hidden = true;
  delete $('plans').dataset.open;
}

function showPlan(id) {
  const plan = state.plans.find((candidate) => candidate.id === id);
  if (!plan) {
    closePlan();
    return;
  }
  $('readerEmpty').hidden = true;
  $('readerBody').hidden = false;
  $('rTitle').textContent = plan.title;
  $('rMeta').innerHTML = spans([plan.id, dateTime(plan.modified), `${Math.max(1, Math.round(plan.size / 1024))} KB`]);
  syncFields(plan);
  $('doc').innerHTML = renderMarkdown(plan.body);
  requestAnimationFrame(() => {
    const doc = $('doc');
    const height = doc.scrollHeight - doc.clientHeight;
    doc.scrollTop = height > 0 ? (Number(plan.progress) || 0) * height : 0;
  });
}

function syncFields(plan) {
  $('pin').setAttribute('aria-pressed', plan.pinned);
  $('pin').lastChild.textContent = plan.pinned ? 'Pinned' : 'Pin';
  $('status').value = plan.status;
  const { projects } = state.facets;
  const choices = !plan.project || projects.includes(plan.project) ? projects : [plan.project, ...projects];
  $('planProject').innerHTML = '<option value="" disabled>Unassigned</option>'
    + choices.map((path) => `<option value="${escapeHtml(path)}">${escapeHtml(baseName(path))}</option>`).join('');
  $('planProject').value = plan.project;
  if (document.activeElement !== $('tags')) $('tags').value = plan.tags.join(', ');
  const related = state.plans
    .filter((other) => other.id !== plan.id
      && ((plan.project && other.project === plan.project) || other.tags.some((tag) => plan.tags.includes(tag))))
    .slice(0, 4);
  $('related').hidden = !related.length;
  $('related').innerHTML = '<span>Related</span>'
    + related.map((other) => `<button class="btn" data-id="${escapeHtml(other.id)}" title="${escapeHtml(other.title)}">${escapeHtml(other.title)}</button>`).join('');
}

async function savePlan(change, id = state.open) {
  try {
    state.plans = (await api('/api/plan', { id, ...change })).plans;
  } catch (error) {
    report(error);
  }
  renderPlans();
  if (id === state.open && currentPlan()) syncFields(currentPlan());
}

async function toggleEditing() {
  if (!state.editing) {
    $('editor').value = currentPlan().body;
    setEditing(true);
    $('editor').focus();
    return;
  }
  try {
    state.plans = (await api('/api/plan', { id: state.open, body: $('editor').value })).plans;
  } catch (error) {
    report(error);
    return;
  }
  setEditing(false);
  renderPlans();
  showPlan(state.open);
}

async function deletePlan() {
  if (!state.open || !confirm('Delete this plan?\n\nThe markdown file is removed from ~/.claude/plans. This cannot be undone.')) return;
  try {
    state.plans = (await api('/api/plan/delete', { id: state.open })).plans;
  } catch (error) {
    report(error);
    return;
  }
  closePlan();
  renderPlans();
}

function saveReadingPosition() {
  const doc = $('doc');
  const height = doc.scrollHeight - doc.clientHeight;
  const id = state.open;
  if (!id || height <= 0) return;
  const at = Math.min(1, Math.max(0, doc.scrollTop / height));
  clearTimeout(progressTimer);
  progressTimer = setTimeout(() => {
    const plan = state.plans.find((candidate) => candidate.id === id);
    if (plan && Math.abs((Number(plan.progress) || 0) - at) * height > 1) savePlan({ progress: at }, id);
  }, 400);
}

export function initPlans() {
  $('planList').addEventListener('click', (event) => {
    const row = event.target.closest('.row');
    if (row) openPlan(row.dataset.id);
  });
  $('planList').addEventListener('keydown', (event) => {
    if ((event.key === 'Delete' || event.key === 'Backspace') && event.target.closest('.row')) {
      event.preventDefault();
      deletePlan();
    }
  });
  onArrowKeys($('planList'), openPlan);
  $('pin').onclick = () => savePlan({ pinned: $('pin').getAttribute('aria-pressed') !== 'true' });
  $('status').onchange = () => savePlan({ status: $('status').value });
  $('planProject').onchange = () => savePlan({ project: $('planProject').value });
  $('tags').addEventListener('change', () => savePlan({ tags: $('tags').value.split(',') }));
  $('openFile').onclick = () => api('/api/plan/open', { id: state.open }).catch(report);
  $('related').onclick = (event) => {
    const button = event.target.closest('button');
    if (button) openPlan(button.dataset.id);
  };
  $('back').onclick = () => {
    if (!mayLeaveEdits()) return;
    closePlan();
    renderPlans();
  };
  $('edit').onclick = toggleEditing;
  $('editor').addEventListener('keydown', (event) => {
    if (commandKey(event) && event.key === 's') {
      event.preventDefault();
      $('edit').click();
    }
  });
  $('del').onclick = deletePlan;
  $('doc').addEventListener('scroll', saveReadingPosition);
}

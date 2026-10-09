import { api } from './api.js';
import { $, escapeHtml, isContextMenuKey } from './dom.js';
import { baseName } from './format.js';
import { openMenu } from './menu.js';
import { state } from './state.js';
import { report, subtitle } from './status.js';

const FOLD_ICON = '<svg class="ico" viewBox="0 0 10 10" aria-hidden="true"><path d="M3.5 2 6.5 5l-3 3"/></svg>';

let showArchived = false;
let onProjectChange;

const projectButton = (path, name, count, extra = '') =>
  `<button class="proj${extra}" data-path="${escapeHtml(path)}" title="${escapeHtml(path || name)}" aria-current="${path === state.project}"><span class="n">${escapeHtml(name)}</span><span class="c">${count}</span></button>`;

export function renderProjects() {
  const { facets } = state;
  const hidden = new Set(facets.archived);
  const shown = facets.projects.filter((path) => !hidden.has(path));
  const archivedSection = hidden.size
    ? `<button class="fold" id="fold" aria-expanded="${showArchived}">${FOLD_ICON}Archived<span class="c">${hidden.size}</span></button>`
      + (showArchived ? facets.archived.map((path) => projectButton(path, baseName(path), facets.counts[path], ' archived')).join('') : '')
    : '';
  $('projects').innerHTML = projectButton('', 'All projects', shown.reduce((sum, path) => sum + facets.counts[path], 0))
    + shown.map((path) => projectButton(path, baseName(path), facets.counts[path])).join('')
    + archivedSection;
}

export function fillBranches() {
  const was = $('branch').value;
  $('branch').innerHTML = '<option value="">Any branch</option>'
    + state.facets.branches.map((branch) => `<option value="${escapeHtml(branch)}">${escapeHtml(branch)}</option>`).join('');
  if (state.facets.branches.includes(was)) $('branch').value = was;
}

async function archive(path, archived) {
  try {
    const result = await api('/api/project/archive', { path, archived });
    state.plans = result.plans;
    state.facets = result.facets;
  } catch (error) {
    report(error);
    return;
  }
  if (archived && state.project === path) state.project = '';
  if (!state.facets.archived.length) showArchived = false;
  renderProjects();
  await onProjectChange();
  subtitle(`${archived ? 'Archived' : 'Unarchived'} ${baseName(path)}`, { flash: true });
}

const projectMenu = (path) => (state.facets.archived.includes(path)
  ? [{ label: 'Unarchive Project', run: () => archive(path, false) }]
  : [{ label: 'Archive Project', run: () => archive(path, true) }]);

export function initSidebar(projectChanged) {
  onProjectChange = projectChanged;
  $('projects').addEventListener('click', (event) => {
    if (event.target.closest('#fold')) {
      showArchived = !showArchived;
      renderProjects();
      $('fold').focus();
      return;
    }
    const button = event.target.closest('.proj');
    if (!button) return;
    state.project = button.dataset.path;
    renderProjects();
    document.body.classList.remove('show-side');
    onProjectChange();
  });
  $('projects').addEventListener('contextmenu', (event) => {
    const button = event.target.closest('.proj');
    if (!button?.dataset.path) return;
    event.preventDefault();
    openMenu(event.clientX, event.clientY, projectMenu(button.dataset.path));
  });
  $('projects').addEventListener('keydown', (event) => {
    const button = event.target.closest('.proj');
    if (!button?.dataset.path || !isContextMenuKey(event)) return;
    event.preventDefault();
    const box = button.getBoundingClientRect();
    openMenu(box.left + 20, box.bottom - 4, projectMenu(button.dataset.path));
  });
}

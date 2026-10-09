import { api } from './api.js';
import { $, commandKey, press } from './dom.js';
import { closeMenu, initMenu } from './menu.js';
import { hasUnsavedEdits, initPlans, loadPlans, planHash, renderPlans, shownPlans } from './plans.js';
import { copySessionId, initSessions, runSearch } from './sessions.js';
import { fillBranches, initSidebar, renderProjects } from './sidebar.js';
import { state } from './state.js';
import { report, setCountSource, subtitle } from './status.js';

const CHEVRON = '<svg class="ico chev" viewBox="0 0 8 12" aria-hidden="true"><path d="M1.5 4.5 4 2l2.5 2.5M1.5 7.5 4 10l2.5-2.5"/></svg>';

const narrowScreen = matchMedia('(max-width:760px)');

let typingTimer;

const refresh = () => (state.mode === 'plans' ? renderPlans() : runSearch());

function setMode(next) {
  state.mode = next;
  document.body.dataset.mode = next;
  press($('modes'), $('modes').querySelector(`[data-mode=${next}]`));
  $('q').placeholder = next === 'plans' ? 'Search plans' : 'Search conversations';
  const hash = next === 'sessions'
    ? location.pathname
    : state.open ? planHash(state.open) : location.hash.startsWith('#plans/') ? location.hash : '#plans';
  history.replaceState(null, '', hash);
  if (next === 'plans') loadPlans();
  else runSearch();
}

async function rebuildIndex() {
  subtitle('Rebuilding index...');
  $('rebuild').disabled = true;
  try {
    state.facets = (await api('/api/rebuild', {})).facets;
    renderProjects();
    fillBranches();
    await runSearch();
  } catch (error) {
    report(error);
  } finally {
    $('rebuild').disabled = false;
  }
}

function initToolbar() {
  $('modes').addEventListener('click', (event) => {
    const button = event.target.closest('button');
    if (button && button.dataset.mode !== state.mode) setMode(button.dataset.mode);
  });
  $('when').addEventListener('click', (event) => {
    const button = event.target.closest('button');
    if (!button) return;
    state.daysBack = button.dataset.back;
    press($('when'), button);
    runSearch();
  });
  ['role', 'branch', 'sort'].forEach((id) => $(id).addEventListener('change', runSearch));
  $('q').addEventListener('input', () => {
    clearTimeout(typingTimer);
    typingTimer = setTimeout(refresh, state.mode === 'plans' ? 60 : 120);
  });
  $('rebuild').onclick = rebuildIndex;
  $('sideToggle').onclick = () => document.body.classList.toggle(narrowScreen.matches ? 'show-side' : 'no-side');
}

function initWindow() {
  document.addEventListener('pointerdown', (event) => {
    if (!event.target.closest('#menu')) closeMenu();
    if (narrowScreen.matches && !event.target.closest('#sidebar,#sideToggle')) document.body.classList.remove('show-side');
  });
  document.addEventListener('keydown', (event) => {
    if (commandKey(event) && event.key.toLowerCase() === 'f') {
      event.preventDefault();
      $('q').focus();
      $('q').select();
    } else if (commandKey(event) && event.key.toLowerCase() === 'c' && !event.shiftKey && state.mode === 'sessions'
      && state.selected && !getSelection().toString() && !event.target.matches('input,textarea')) {
      event.preventDefault();
      copySessionId(state.selected);
    }
  });
  addEventListener('blur', closeMenu);
  addEventListener('beforeunload', (event) => {
    if (hasUnsavedEdits()) event.preventDefault();
  });
  new ResizeObserver(([entry]) => document.body.style.setProperty('--bar', `${entry.target.offsetHeight}px`))
    .observe($('toolbar'));
}

document.querySelectorAll('.pop').forEach((pop) => pop.insertAdjacentHTML('beforeend', CHEVRON));
setCountSource(() => (state.mode === 'plans'
  ? [shownPlans().length, state.plans.length, 'plans']
  : [state.sessions.length, state.facets.total, 'sessions']));
initMenu();
initSidebar(refresh);
initSessions();
initPlans();
initToolbar();
initWindow();

api('/api/facets')
  .then((facets) => {
    state.facets = facets;
    renderProjects();
    fillBranches();
    setMode(location.hash.startsWith('#plans') ? 'plans' : 'sessions');
  })
  .catch(report);

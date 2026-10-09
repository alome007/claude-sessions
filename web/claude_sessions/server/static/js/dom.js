export const $ = (id) => document.getElementById(id);

export const isMac = /Mac/.test(navigator.platform);

export const commandKey = (event) => (isMac ? event.metaKey : event.ctrlKey);

export const isContextMenuKey = (event) => event.key === 'ContextMenu' || (event.shiftKey && event.key === 'F10');

const ENTITIES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' };

export const escapeHtml = (value) => String(value).replace(/[&<>"]/g, (c) => ENTITIES[c]);

export const spans = (items) =>
  items.filter(Boolean).map((item) => `<span>${escapeHtml(item)}</span>`).join('');

export function press(group, on) {
  group.querySelectorAll('button').forEach((button) => button.setAttribute('aria-pressed', button === on));
}

export function selectRow(list, id, focus) {
  for (const row of list.querySelectorAll('.row')) {
    const on = row.dataset.id === id;
    row.setAttribute('aria-selected', on);
    row.tabIndex = on ? 0 : -1;
    if (on && focus) {
      row.focus();
      row.scrollIntoView({ block: 'nearest' });
    }
  }
}

export function onArrowKeys(list, pick) {
  list.addEventListener('keydown', (event) => {
    const row = event.target.closest('.row');
    if (!row || (event.key !== 'ArrowDown' && event.key !== 'ArrowUp')) return;
    event.preventDefault();
    const next = event.key === 'ArrowDown' ? row.nextElementSibling : row.previousElementSibling;
    if (next?.classList.contains('row')) pick(next.dataset.id, true);
  });
}

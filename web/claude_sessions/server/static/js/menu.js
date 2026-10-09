import { $, escapeHtml } from './dom.js';

let entries = [];
let returnFocus = null;

export function openMenu(x, y, items) {
  const menu = $('menu');
  entries = items;
  menu.innerHTML = items
    .map((item, i) => (item
      ? `<button role="menuitem" data-i="${i}">${escapeHtml(item.label)}${item.key ? `<kbd>${escapeHtml(item.key)}</kbd>` : ''}</button>`
      : '<hr>'))
    .join('');
  returnFocus = document.activeElement;
  menu.hidden = false;
  menu.style.left = `${Math.max(8, Math.min(x, innerWidth - menu.offsetWidth - 8))}px`;
  menu.style.top = `${Math.max(8, Math.min(y, innerHeight - menu.offsetHeight - 8))}px`;
  menu.querySelector('button').focus();
}

export function closeMenu() {
  if ($('menu').hidden) return;
  $('menu').hidden = true;
  returnFocus?.focus();
}

export function initMenu() {
  $('menu').addEventListener('click', (event) => {
    const button = event.target.closest('button');
    if (!button) return;
    closeMenu();
    entries[button.dataset.i].run();
  });
  $('menu').addEventListener('keydown', (event) => {
    const buttons = [...$('menu').querySelectorAll('button')];
    const at = buttons.indexOf(document.activeElement);
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      buttons[(at + (event.key === 'ArrowDown' ? 1 : buttons.length - 1)) % buttons.length].focus();
    } else if (event.key === 'Escape' || event.key === 'Tab') {
      event.preventDefault();
      closeMenu();
    }
  });
}

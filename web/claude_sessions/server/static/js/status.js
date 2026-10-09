import { $ } from './dom.js';

let flashTimer;
let countSource;

export function setCountSource(source) {
  countSource = source;
}

export function showCount() {
  const [shown, total, unit] = countSource();
  subtitle(shown === total ? `${total} ${unit}` : `${shown} of ${total} ${unit}`);
}

export function subtitle(text, { error = false, flash = false } = {}) {
  clearTimeout(flashTimer);
  $('subtitle').textContent = text;
  $('subtitle').classList.toggle('err', error);
  if (flash) flashTimer = setTimeout(showCount, 1400);
}

export const report = (error) => subtitle(error.message, { error: true });

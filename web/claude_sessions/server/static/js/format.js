import { escapeHtml } from './dom.js';

export const highlightMatches = (snippet) =>
  escapeHtml(snippet)
    .split('\u0001')
    .map((part) => part.split('\u0002'))
    .flatMap((part, i) => (i ? ['<mark>', part[0], '</mark>', part[1] || ''] : [part[0]]))
    .join('');

export const baseName = (path) => path.split('/').pop() || path;

export const repoOf = (path) => path.split('/.claude/worktrees/')[0];

export const dateTime = (seconds) =>
  new Date(seconds * 1000).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' });

export const date = (seconds) => new Date(seconds * 1000).toLocaleDateString([], { dateStyle: 'medium' });

export const isoDay = (day) => new Date(day - day.getTimezoneOffset() * 6e4).toISOString().slice(0, 10);

export const shellQuote = (text) => (/^[\w@%+=:,./-]+$/.test(text) ? text : `'${text.replace(/'/g, "'\\''")}'`);

export const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

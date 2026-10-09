import { escapeHtml } from './dom.js';

function inline(text) {
  let out = '';
  let i = 0;
  let match;
  const take = (open, close) => {
    if (!text.startsWith(open, i)) return null;
    const from = i + open.length;
    if (from >= text.length) return null;
    const end = text.indexOf(close, from);
    if (end < 0) return null;
    i = end + close.length;
    return text.slice(from, end);
  };
  while (i < text.length) {
    if ((match = take('`', '`')) !== null) {
      out += `<code>${escapeHtml(match)}</code>`;
    } else if ((match = take('**', '**')) !== null) {
      out += `<strong>${escapeHtml(match)}</strong>`;
    } else if (text[i] === '[' && (match = /^\[([^\]]*)\]\(([^)]*)\)/.exec(text.slice(i)))) {
      out += /^https?:\/\//.test(match[2])
        ? `<a href="${escapeHtml(match[2])}" target="_blank" rel="noreferrer">${escapeHtml(match[1])}</a>`
        : escapeHtml(match[1]);
      i += match[0].length;
    } else if (text[i] === '*' && (match = take('*', '*')) !== null) {
      out += `<em>${escapeHtml(match)}</em>`;
    } else {
      out += escapeHtml(text[i++]);
    }
  }
  return out;
}

function block(line) {
  const heading = /^(#{1,4}) (.*)$/.exec(line);
  if (heading) return `<h${heading[1].length}>${inline(heading[2])}</h${heading[1].length}>`;
  const trimmed = line.replace(/^ +/, '');
  const depth = Math.floor((line.length - trimmed.length) / 2);
  if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
    return `<div class="li" style="--d:${depth}">${inline(trimmed.slice(2))}</div>`;
  }
  if (/^\d+\./.test(trimmed)) return `<div class="li n" style="--d:${depth}">${inline(trimmed)}</div>`;
  if (trimmed.startsWith('> ')) return `<blockquote>${inline(trimmed.slice(2))}</blockquote>`;
  if (trimmed.startsWith('---') || trimmed.startsWith('***')) return '<hr>';
  return trimmed ? `<p>${inline(line)}</p>` : '';
}

const isTableRow = (line) => {
  const trimmed = line.trim();
  return trimmed.startsWith('|') && trimmed.slice(1).includes('|');
};

const isTableRule = (line) => {
  const trimmed = line.trim();
  return trimmed.startsWith('|') && /^[|: -]+$/.test(trimmed);
};

const tableCells = (line) => {
  const cells = line.trim().split('|').map((cell) => cell.trim());
  if (cells[0] === '') cells.shift();
  if (cells.at(-1) === '') cells.pop();
  return cells;
};

function table(head, body) {
  const columns = Math.max(head.length, ...body.map((row) => row.length));
  const tr = (row, tag) =>
    `<tr>${Array.from({ length: columns }, (_, c) => `<${tag}>${inline(row[c] ?? '')}</${tag}>`).join('')}</tr>`;
  return `<div class="table"><table><thead>${tr(head, 'th')}</thead><tbody>${body.map((row) => tr(row, 'td')).join('')}</tbody></table></div>`;
}

export function renderMarkdown(text) {
  const lines = text.replace(/\r\n/g, '\n').split('\n');
  const out = [];
  for (let i = 0; i < lines.length;) {
    const line = lines[i];
    if (line.startsWith('```')) {
      const code = [];
      i++;
      while (i < lines.length && !lines[i].startsWith('```')) code.push(lines[i++]);
      i++;
      out.push(`<pre><code>${escapeHtml(code.join('\n'))}</code></pre>`);
    } else if (isTableRow(line) && isTableRule(lines[i + 1] ?? '')) {
      const head = tableCells(line);
      const body = [];
      i += 2;
      while (i < lines.length && isTableRow(lines[i])) body.push(tableCells(lines[i++]));
      out.push(table(head, body));
    } else {
      out.push(block(line));
      i++;
    }
  }
  return out.join('');
}

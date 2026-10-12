#!/usr/bin/env node
// Execute the shipped gallery script with a DOM fixture to exercise selection events.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const swift = fs.readFileSync(path.join(root, 'Sources/LocalShare/MediaGallery.swift'), 'utf8');
const script = swift.split('static let script = #"""')[1].split('"""#')[0];
const limit = Number(fs.readFileSync(path.join(root, 'Sources/LocalShare/BatchDownload.swift'), 'utf8')
  .match(/static let maxFiles = (\d+)/)[1]);
const translations = [...fs.readFileSync(path.join(root, 'Sources/LocalShare/Lang.swift'), 'utf8')
  .matchAll(/\("(\w+)", "([^"\n]*)", "([^"\n]*)"\)/g)];

function fixture(size, lang) {
  const nodes = [], submissions = [];
  class Element {
    constructor(tag) {
      this.tagName = tag.toUpperCase(); this.children = []; this.events = {};
      this.style = {}; this.dataset = {}; this.classes = new Set();
      this.classList = { add: c => this.classes.add(c), toggle: (c, on) => on ? this.classes.add(c) : this.classes.delete(c) };
      nodes.push(this);
    }
    appendChild(child) { this.children.push(child); return child; }
    prepend(child) { this.children.unshift(child); }
    after() {}
    setAttribute(name, value) { this[name] = value; }
    addEventListener(name, fn) { this.events[name] = fn; }
    querySelector(selector) {
      if (selector === '[data-kind]') return this.children[0];
      return this.children.find(c => selector === 'a' ? c.tagName === 'A' : '.' + c.className === selector);
    }
    querySelectorAll(selector) { return selector === '[data-kind]' ? this.children : []; }
    submit() { submissions.push(JSON.parse(this.children[0].value)); }
    remove() {}
  }
  const list = new Element('ul'), toolbar = new Element('div'), body = new Element('body');
  const rows = Array.from({ length: size }, (_, i) => {
    const row = new Element('li'); row.dataset = { kind: 'file', type: 'text' };
    const a = new Element('a'); a.href = `https://example.com/share/demo/sub%20folder/file-${i}.txt`;
    const name = new Element('span'); name.className = 'nm'; name.textContent = `file-${i}.txt`;
    row.appendChild(a); row.appendChild(name); list.appendChild(row); return row;
  });
  const t = Object.fromEntries(translations.map(m => [m[1], m[lang]]));
  vm.runInNewContext(script, {
    URL, LS_I18N: t, LS_ROOT: '../', LS_BATCH_DOWNLOAD: true, LS_BATCH_LIMIT: limit,
    location: { href: 'https://example.com/share/demo/sub%20folder/', search: '' },
    document: { body, createElement: tag => new Element(tag), querySelector: s => s === '.list' ? list : toolbar },
    window: { addEventListener() {} }, sessionStorage: { getItem() { return null; }, setItem() {} },
    IntersectionObserver: class { disconnect() {} observe() {} },
  });
  return { list, rows, submissions, t,
    batch: nodes.find(n => n.className === 'batch-toggle'),
    all: nodes.find(n => n.textContent === t.selectAll),
    download: nodes.find(n => n.className === 'download-selected'),
    count: nodes.find(n => n.className === 'selected-count') };
}

for (const lang of [2, 3]) {
  for (const size of [limit, limit + 1]) {
    const f = fixture(size, lang);
    f.batch.onclick(); assert.equal(f.download.disabled, true);
    if (size > limit) assert.equal(f.all.textContent, f.t.selectUpToN.replace('{n}', limit));
    f.all.onclick();
    assert.equal(f.all.textContent, f.t.clearSelection);
    assert.equal(f.rows.filter(r => r.querySelector('.pick').checked).length, limit);
    assert.ok(f.count.textContent.includes(f.t.selectionLimit.replace('{n}', limit)));
    assert.equal(f.download.disabled, false);
    if (size > limit) {
      assert.equal(f.rows[limit].querySelector('.pick').disabled, true);
      f.rows[limit].querySelector('a').events.click({ preventDefault() {} });
      assert.equal(f.rows[limit].querySelector('.pick').checked, false);
      f.rows[0].querySelector('a').events.click({ preventDefault() {} });
      assert.equal(f.rows[limit].querySelector('.pick').disabled, false);
      f.rows[limit].querySelector('.pick').events.change();
    }
    f.download.onclick(); assert.equal(f.submissions[0].length, limit);
    assert.ok(f.submissions[0].every(p => p.startsWith('/sub%20folder/')));
    f.all.onclick(); assert.equal(f.download.disabled, true);
    f.all.onclick();
    f.rows.slice(0, 500).forEach(r => { r.style.display = 'none'; });
    f.list.events.listingchange();
    assert.equal(f.rows.filter(r => r.querySelector('.pick').checked).length, limit - 500);
    assert.equal(f.rows.at(-1).querySelector('.pick').disabled, false);
    f.batch.onclick(); assert.equal(f.rows.filter(r => r.querySelector('.pick').checked).length, 0);
  }
}
console.log('PASS: 1000/1001 selections, checkbox and row limits, submission, filtering, reset and bilingual hints');

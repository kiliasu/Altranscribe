// Run with: node --test test/files/transcript_player_test.cjs
// Exercise the actual exported script with deterministic media/viewport events.
const { readFileSync } = require('node:fs');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const source = readFileSync('lib/data/services/files/transcript_export.dart', 'utf8');
const script = source.match(/static const _script = '''([\s\S]*?)''';/)[1];

function playerFixture({ reduced = false } = {}) {
  function element(dataset = {}) {
    const handlers = new Map(), classes = new Set(), attributes = new Map();
    return { dataset, classes, attributes,
      addEventListener: (name, fn) => handlers.set(name, fn),
      emit: (name) => handlers.get(name)?.(),
      classList: { add: (name) => classes.add(name), remove: (name) => classes.delete(name) },
      setAttribute: (key, value) => attributes.set(key, value),
      removeAttribute: (key) => attributes.delete(key),
      getBoundingClientRect: () => ({ top: 900, bottom: 1000, height: 100 }),
    };
  }
  const player = Object.assign(element(), { currentTime: 0, play: () => Promise.resolve() });
  const follow = Object.assign(element(), { checked: true });
  const items = [element({ start: '0', end: '2000' }), element({ start: '3000', end: '5000' }),
    element({ start: '4000', end: '6000' })];
  const scrolls = [];
  vm.runInNewContext(script, {
    document: {
      getElementById: (id) => id === 'player' ? player : follow,
      querySelectorAll: () => items,
      querySelector: () => ({ getBoundingClientRect: () => ({ bottom: 100 }) }),
    },
    window: { innerHeight: 700, scrollY: 0,
      matchMedia: () => ({ matches: reduced }), scrollTo: (options) => scrolls.push(options) },
  });
  return { player, follow, items, scrolls };
}

test('time changes update only the active sentence and scroll once per sentence', () => {
  const { player, items, scrolls } = playerFixture();
  player.emit('timeupdate');
  assert(items[0].classes.has('active'));
  assert.equal(items[0].attributes.get('aria-current'), 'true');
  assert.equal(scrolls.length, 1);
  player.currentTime = 1; player.emit('timeupdate');
  assert.equal(scrolls.length, 1);
  player.currentTime = 2.5; player.emit('timeupdate');
  assert(items[1].classes.has('active')); // Nearest sentence in a silent gap.
  player.currentTime = 4.5; player.emit('timeupdate');
  assert(items[2].classes.has('active')); // Latest-starting overlapping segment.
  player.currentTime = 6; player.emit('ended');
  assert(items[2].classes.has('active')); // Keep the nearest sentence at the end.
});

test('paused scrubbing follows immediately, including gaps and an already visible sentence', () => {
  const { player, items, scrolls, follow } = playerFixture();
  player.paused = true;
  items[1].getBoundingClientRect = () => ({ top: 200, bottom: 300, height: 100 });
  player.currentTime = 2.8; player.seeking = true; player.emit('seeking');
  assert(items[1].classes.has('active'));
  assert.equal(scrolls.length, 1);
  assert.equal(scrolls[0].behavior, 'auto');
  assert.equal(player.paused, true);
  player.currentTime = 0.7; player.emit('timeupdate');
  assert(items[0].classes.has('active'));
  assert.equal(scrolls.at(-1).behavior, 'auto');
  player.currentTime = 9; player.seeking = false; player.emit('seeked');
  assert(items[2].classes.has('active'));
  follow.checked = false;
  const count = scrolls.length;
  player.currentTime = 0; player.emit('seeking');
  assert(items[0].classes.has('active'));
  assert.equal(scrolls.length, count);
});

test('manual reading keeps highlights without scrolling; reenabling follows immediately', () => {
  const { player, follow, items, scrolls } = playerFixture();
  follow.checked = false; follow.emit('change');
  player.currentTime = 3.5; player.emit('seeked');
  assert(items[1].classes.has('active'));
  assert.equal(scrolls.length, 0);
  follow.checked = true; follow.emit('change');
  assert.equal(scrolls.length, 1);
  assert.equal(scrolls[0].behavior, 'auto');
  items[0].emit('click');
  assert.equal(player.currentTime, 0);
  assert(items[0].classes.has('active'));
});

test('reduced motion and visible rows avoid unnecessary animation and scrolling', () => {
  const { player, items, scrolls } = playerFixture({ reduced: true });
  player.emit('timeupdate');
  assert.equal(scrolls[0].behavior, 'auto');
  items[1].getBoundingClientRect = () => ({ top: 200, bottom: 300, height: 100 });
  player.currentTime = 3.5; player.emit('timeupdate');
  assert.equal(scrolls.length, 1);
});

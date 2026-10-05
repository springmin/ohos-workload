/*
 * Offline unit test for the a11y dump model. Runs on the host with the plain node binary
 * (node >= 23 strips the types), no device and no hvigor needed:
 *
 *   node test/a11y-client/offline/a11y-model.test.ts
 *
 * It is the fallback evidence for the dump contract when the on-device accessibility
 * extension cannot be enabled (see docs/plans/2026-10-05-ohos-a11y-client.md).
 */
import assert from 'node:assert/strict';
import type { A11yNodeView } from '../entry/src/main/ets/a11y/A11yModel.ts';
import {
  EMPTY_RECT,
  compact,
  dumpToJson,
  findClickTarget,
  makeDump,
  matchesClickLabel,
  nodeLabel,
  roleText,
  summarize,
  summaryLine,
  toNodeLine,
} from '../entry/src/main/ets/a11y/A11yModel.ts';

function node(partial: Partial<A11yNodeView>): A11yNodeView {
  return Object.assign({
    id: 0, parentId: -1, depth: 0, role: 'Text', text: '', label: '', description: '',
    a11yText: '', contents: '', hintText: '', resourceName: '', inspectorKey: '',
    clickable: false, longClickable: false, focusable: false, a11yFocused: false, focused: false,
    checkable: false, checked: false, selected: false, scrollable: false, visible: true,
    enabled: true, editable: false, windowId: 10, rect: EMPTY_RECT,
  }, partial);
}

let checks = 0;
function check(name: string, body: () => void): void {
  body();
  checks++;
  console.log('  ok ' + name);
}

check('label precedence text > a11yText > description > contents > hint', () => {
  assert.equal(nodeLabel(node({ text: 'T', a11yText: 'A', description: 'D' })), 'T');
  assert.equal(nodeLabel(node({ a11yText: 'A', description: 'D' })), 'A');
  assert.equal(nodeLabel(node({ description: 'D', contents: 'C' })), 'D');
  assert.equal(nodeLabel(node({ contents: 'C', hintText: 'H' })), 'C');
  assert.equal(nodeLabel(node({ hintText: 'H' })), 'H');
});

check('role falls back to unknown and compact truncates', () => {
  assert.equal(roleText(node({ role: '' })), 'unknown');
  assert.equal(roleText(node({ role: 'Button' })), 'Button');
  assert.equal(compact('abcdef', 3), 'abc');
  assert.equal(compact('abc', 3), 'abc');
});

check('click target matcher picks the first clickable node with the label part', () => {
  const nodes = [
    node({ id: 0, role: 'Text', text: 'Count: 3', clickable: false }),
    node({ id: 1, role: 'Button', text: 'Count: 3', clickable: true }),
    node({ id: 2, role: 'Button', text: 'Run animations', clickable: true }),
  ];
  const target = findClickTarget(nodes, matchesClickLabel('Count:'));
  assert.equal(target?.id, 1);
  // Negative control: the same label on a non-clickable node must never match.
  assert.equal(findClickTarget([nodes[0]], matchesClickLabel('Count:')), null);
  assert.equal(findClickTarget(nodes, matchesClickLabel('Run animations'))?.id, 2);
});

check('node line carries role/label/flags/geometry and stays compact', () => {
  const line = toNodeLine(node({
    id: 7, parentId: 3, depth: 2, role: 'Button', text: 'Count: 1', clickable: true,
    focusable: true, windowId: 42, rect: { left: 1, top: 2, width: 3, height: 4 },
  }));
  assert.ok(line.indexOf('"id":7') >= 0);
  assert.ok(line.indexOf('"role":"Button"') >= 0);
  assert.ok(line.indexOf('"label":"Count: 1"') >= 0);
  assert.ok(line.indexOf('"click":true') >= 0);
  assert.ok(line.indexOf('"rect":[1,2,3,4]') >= 0);
  assert.ok(line.length < 320);
});

check('summary aggregates roles, focus and the target window', () => {
  const nodes = [
    node({ id: 0, parentId: -1, windowId: 10, role: 'Window' }),
    node({ id: 1, parentId: 0, depth: 1, windowId: 10, role: 'Button', text: 'A', clickable: true, focusable: true, focused: true }),
    node({ id: 2, parentId: 0, depth: 1, windowId: 11, role: 'Button', text: 'B', clickable: true }),
    node({ id: 3, parentId: 0, depth: 1, windowId: 10, role: 'Text', text: 'C', a11yFocused: true }),
  ];
  const summary = summarize(nodes, [10], 'com.example.hellomauiapp@10,other@11');
  assert.equal(summary.nodes, 4);
  assert.equal(summary.targetNodes, 3);
  assert.equal(summary.clickable, 2);
  assert.equal(summary.focusable, 1);
  assert.equal(summary.focusedId, 1);
  assert.equal(summary.a11yFocusedId, 3);
  assert.ok(summary.roles.indexOf('Button=2') >= 0);
  assert.ok(summaryLine(summary).indexOf('targetNodes=3') >= 0);
});

check('dump document round-trips through JSON with schema and reason', () => {
  const dump = makeDump('onConnect', 'com.example.hellomauiapp', 1234, false, [node({ id: 0 })]);
  const parsed = JSON.parse(dumpToJson(dump)) as { schema: number; reason: string; nodes: A11yNodeView[] };
  assert.equal(parsed.schema, 1);
  assert.equal(parsed.reason, 'onConnect');
  assert.equal(parsed.nodes.length, 1);
  assert.equal(parsed.nodes[0].windowId, 10);
});

console.log('a11y-model: ' + checks + ' checks passed');

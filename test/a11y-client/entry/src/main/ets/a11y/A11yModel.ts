/*
 * Pure, dependency-free helpers for the accessibility shadow-tree dump. The extension
 * ability (A11yExtAbility.ets) reads the OS accessibility elements; this module turns the
 * snaphots into the dump document and the hilog lines. It imports nothing so the same file
 * runs under node for the offline unit tests (test/a11y-client/offline).
 */

export interface A11yRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface A11yNodeView {
  id: number;
  parentId: number;
  depth: number;
  role: string;
  text: string;
  label: string;
  description: string;
  a11yText: string;
  contents: string;
  hintText: string;
  resourceName: string;
  inspectorKey: string;
  clickable: boolean;
  longClickable: boolean;
  focusable: boolean;
  a11yFocused: boolean;
  focused: boolean;
  checkable: boolean;
  checked: boolean;
  selected: boolean;
  scrollable: boolean;
  visible: boolean;
  enabled: boolean;
  editable: boolean;
  windowId: number;
  rect: A11yRect;
}

export interface A11yDump {
  schema: number;
  generatedAtMs: number;
  reason: string;
  targetBundle: string;
  truncated: boolean;
  nodes: A11yNodeView[];
}

export interface A11ySummary {
  nodes: number;
  targetNodes: number;
  windows: string;
  roles: string;
  focusable: number;
  clickable: number;
  focusedId: number;
  a11yFocusedId: number;
}

export const EMPTY_RECT: A11yRect = { left: 0, top: 0, width: 0, height: 0 };

export function nodeLabel(node: A11yNodeView): string {
  if (node.text.length > 0) {
    return node.text;
  }
  if (node.a11yText.length > 0) {
    return node.a11yText;
  }
  if (node.description.length > 0) {
    return node.description;
  }
  if (node.contents.length > 0) {
    return node.contents;
  }
  return node.hintText;
}

export function roleText(node: A11yNodeView): string {
  return node.role.length > 0 ? node.role : 'unknown';
}

export function isActionTarget(node: A11yNodeView): boolean {
  return node.clickable || node.focusable || node.checkable || node.editable || node.scrollable;
}

export function compact(value: string, max: number): string {
  if (value.length <= max) {
    return value;
  }
  return value.substring(0, max);
}

/* One compact JSON line per node for hilog; no spaces to keep lines under the hilog limit. */
export function toNodeLine(node: A11yNodeView): string {
  return JSON.stringify({
    id: node.id,
    parent: node.parentId,
    depth: node.depth,
    role: roleText(node),
    label: compact(nodeLabel(node), 120),
    click: node.clickable,
    focus: node.focusable,
    a11yFocus: node.a11yFocused,
    checked: node.checked,
    selected: node.selected,
    editable: node.editable,
    scrollable: node.scrollable,
    visible: node.visible,
    window: node.windowId,
    rect: [node.rect.left, node.rect.top, node.rect.width, node.rect.height],
  });
}

/* First node accepted by the predicate; nodes are the traversal-ordered snapshots. */
export function findClickTarget(
  nodes: A11yNodeView[],
  matches: (node: A11yNodeView) => boolean,
): A11yNodeView | null {
  for (let i = 0; i < nodes.length; i++) {
    if (matches(nodes[i])) {
      return nodes[i];
    }
  }
  return null;
}

export function matchesClickLabel(labelPart: string): (node: A11yNodeView) => boolean {
  return (node: A11yNodeView): boolean => {
    return node.clickable && nodeLabel(node).indexOf(labelPart) >= 0;
  };
}

export function summarize(nodes: A11yNodeView[], targetWindowIds: number[], windowText: string): A11ySummary {
  const roles: string[] = [];
  const roleCounts: number[] = [];
  let focusable = 0;
  let clickable = 0;
  let focusedId = -1;
  let a11yFocusedId = -1;
  let targetNodes = 0;
  for (let i = 0; i < nodes.length; i++) {
    const node = nodes[i];
    const role = roleText(node);
    const at = roles.indexOf(role);
    if (at >= 0) {
      roleCounts[at] = roleCounts[at] + 1;
    } else {
      roles.push(role);
      roleCounts.push(1);
    }
    if (node.focusable) {
      focusable++;
    }
    if (node.clickable) {
      clickable++;
    }
    if (node.focused && focusedId < 0) {
      focusedId = node.id;
    }
    if (node.a11yFocused && a11yFocusedId < 0) {
      a11yFocusedId = node.id;
    }
    if (targetWindowIds.indexOf(node.windowId) >= 0) {
      targetNodes++;
    }
  }
  const roleParts: string[] = [];
  for (let i = 0; i < roles.length; i++) {
    roleParts.push(roles[i] + '=' + roleCounts[i]);
  }
  return {
    nodes: nodes.length,
    targetNodes: targetNodes,
    windows: windowText,
    roles: roleParts.join(','),
    focusable: focusable,
    clickable: clickable,
    focusedId: focusedId,
    a11yFocusedId: a11yFocusedId,
  };
}

export function summaryLine(summary: A11ySummary): string {
  return 'nodes=' + summary.nodes +
    ' targetNodes=' + summary.targetNodes +
    ' focusable=' + summary.focusable +
    ' clickable=' + summary.clickable +
    ' focusedId=' + summary.focusedId +
    ' a11yFocusedId=' + summary.a11yFocusedId +
    ' roles=[' + summary.roles + ']' +
    ' windows=[' + summary.windows + ']';
}

export function makeDump(
  reason: string,
  targetBundle: string,
  nowMs: number,
  truncated: boolean,
  nodes: A11yNodeView[],
): A11yDump {
  return {
    schema: 1,
    generatedAtMs: nowMs,
    reason: reason,
    targetBundle: targetBundle,
    truncated: truncated,
    nodes: nodes,
  };
}

export function dumpToJson(dump: A11yDump): string {
  return JSON.stringify(dump, null, 2);
}

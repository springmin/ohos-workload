/*
 * Minimal accessibility client: an AccessibilityExtensionAbility that subscribes to the OS
 * accessibility pipeline, walks the shadow tree of the target app, writes the dump to its
 * files dir and emits per-node hilog lines so the evidence can be captured with hdc hilog.
 *
 * Enable it from Settings (Accessibility -> installed services) or with the device's
 * `accessibility enable -a A11yExtAbility -b com.example.a11yclient -c rg` CLI when present;
 * see test/a11y-client/README.md and docs/plans/2026-10-05-ohos-a11y-client.md.
 */
import {
  AccessibilityExtensionAbility,
  AccessibilityElement,
  AccessibilityEvent,
  ElementAttributeKeys,
  Rect,
} from '@kit.AccessibilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  A11yNodeView,
  A11yRect,
  EMPTY_RECT,
  makeDump,
  nodeLabel,
  summarize,
  summaryLine,
  toNodeLine,
} from './A11yModel';

const DOMAIN: number = 0x3200;
const TAG: string = 'A11yClient';
const TARGET_BUNDLE: string = 'com.example.hellomauiapp';
const DUMP_FILE: string = 'a11y-dump.json';
const MAX_NODES: number = 600;
const MAX_DEPTH: number = 40;
const MAX_DUMPS: number = 12;
const HILOG_NODE_LINES: number = 200;
const CLICK_LABEL: string = 'Count:';

function asString(value: ESObject): string {
  return typeof value === 'string' ? value as string : '';
}

function asBool(value: ESObject): boolean {
  return value === true;
}

function asNumber(value: ESObject): number {
  return typeof value === 'number' ? value as number : -1;
}

function asRect(value: ESObject): A11yRect {
  if (value === undefined || value === null || typeof value !== 'object') {
    return EMPTY_RECT;
  }
  const rect = value as Rect;
  return {
    left: typeof rect.left === 'number' ? rect.left : 0,
    top: typeof rect.top === 'number' ? rect.top : 0,
    width: typeof rect.width === 'number' ? rect.width : 0,
    height: typeof rect.height === 'number' ? rect.height : 0,
  };
}

function shortError(err: ESObject): string {
  if (err === undefined || err === null) {
    return 'unknown';
  }
  const message = (err as Error).message;
  return typeof message === 'string' ? message : JSON.stringify(err);
}

export default class A11yExtAbility extends AccessibilityExtensionAbility {
  private dumping: boolean = false;
  private dumps: number = 0;
  private events: number = 0;
  private clicked: boolean = false;
  private dumpTimer: number = -1;
  private targetWindows: number[] = [];
  private pendingClick: AccessibilityElement | undefined = undefined;
  private pendingClickId: number = -1;

  onConnect(): void {
    hilog.info(DOMAIN, TAG, 'A11YCLIENT onConnect target=%{public}s', TARGET_BUNDLE);
    this.scheduleDump('onConnect', 1500);
  }

  onDisconnect(): void {
    hilog.info(DOMAIN, TAG, 'A11YCLIENT onDisconnect dumps=%{public}d events=%{public}d',
      this.dumps, this.events);
  }

  onAccessibilityEvent(event: AccessibilityEvent): void {
    this.events++;
    const type: string = String(event.eventType);
    hilog.info(DOMAIN, TAG, 'A11YCLIENT event #%{public}d type=%{public}s id=%{public}s',
      this.events, type, String(event.elementId));
    this.scheduleDump('event:' + type, 1200);
  }

  private scheduleDump(reason: string, delayMs: number): void {
    if (this.dumps >= MAX_DUMPS || this.dumpTimer >= 0) {
      return;
    }
    this.dumpTimer = setTimeout(() => {
      this.dumpTimer = -1;
      this.dumpOnce(reason).catch((err: ESObject) => {
        hilog.error(DOMAIN, TAG, 'A11YCLIENT dump failed reason=%{public}s err=%{public}s',
          reason, shortError(err));
      });
    }, delayMs);
  }

  private async dumpOnce(reason: string): Promise<void> {
    if (this.dumping || !this.context) {
      return;
    }
    this.dumping = true;
    this.dumps++;
    const nodes: A11yNodeView[] = [];
    const windowTexts: string[] = [];
    const targetWindows: number[] = [];
    let clickTarget: AccessibilityElement | undefined = undefined;
    let clickTargetId: number = -1;
    let truncated = false;
    try {
      const windows: AccessibilityElement[] = await this.context.getWindows();
      hilog.info(DOMAIN, TAG, 'A11YCLIENT windows=%{public}d', windows.length);
      for (let i = 0; i < windows.length; i++) {
        const windowId = asNumber(await this.attr(windows[i], 'windowId'));
        const bundleName = asString(await this.attr(windows[i], 'bundleName'));
        windowTexts.push(bundleName + '@' + windowId);
        const isTarget = bundleName === TARGET_BUNDLE;
        if (isTarget && windowId >= 0) {
          targetWindows.push(windowId);
        }
        let root: AccessibilityElement | undefined = undefined;
        const rootAttr: ESObject = await this.attr(windows[i], 'rootElement');
        if (rootAttr !== undefined && rootAttr !== null) {
          root = rootAttr as AccessibilityElement;
        } else if (windowId >= 0) {
          root = await this.context.getWindowRootElement(windowId);
        } else {
          root = await this.context.getWindowRootElement();
        }
        const result = await this.walk(root, 0, -1, nodes, isTarget, clickTargetId);
        if (result.clickId >= 0) {
          clickTargetId = result.clickId;
          if (result.clickElement !== undefined) {
            clickTarget = result.clickElement;
          }
        }
        if (nodes.length >= MAX_NODES) {
          truncated = true;
          break;
        }
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'A11YCLIENT walk failed err=%{public}s', shortError(err));
    }
    const summary = summarize(nodes, targetWindows, windowTexts.join(','));
    hilog.info(DOMAIN, TAG, 'A11YCLIENT dump #%{public}d reason=%{public}s truncated=%{public}s %{public}s',
      this.dumps, reason, String(truncated), summaryLine(summary));
    const dump = makeDump(reason, TARGET_BUNDLE, Date.now(), truncated, nodes);
    const path = this.context.filesDir + '/' + DUMP_FILE;
    const written = this.writeDump(path, JSON.stringify(dump, null, 2));
    hilog.info(DOMAIN, TAG, 'A11YCLIENT wrote file=%{public}s bytes=%{public}d', path, written);
    const lines = nodes.length < HILOG_NODE_LINES ? nodes.length : HILOG_NODE_LINES;
    for (let i = 0; i < lines; i++) {
      hilog.info(DOMAIN, TAG, 'A11YCLIENT NODE %{public}s', toNodeLine(nodes[i]));
    }
    this.targetWindows = targetWindows;
    if (targetWindows.length > 0 && clickTarget !== undefined && !this.clicked && reason !== 'afterClick') {
      this.clicked = true;
      this.pendingClick = clickTarget;
      this.pendingClickId = clickTargetId;
      setTimeout(() => {
        this.performClickTest().catch((err: ESObject) => {
          hilog.error(DOMAIN, TAG, 'A11YCLIENT click test failed err=%{public}s', shortError(err));
        });
      }, 800);
    }
    this.dumping = false;
  }

  private async performClickTest(): Promise<void> {
    const element = this.pendingClick;
    if (element === undefined) {
      return;
    }
    const id = this.pendingClickId;
    try {
      await element.performAction('click');
      hilog.info(DOMAIN, TAG, 'A11YCLIENT ACTION click ok id=%{public}d', id);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'A11YCLIENT ACTION click failed id=%{public}d err=%{public}s',
        id, shortError(err));
    }
    setTimeout(() => {
      this.readBackClick(id).catch((err: ESObject) => {
        hilog.error(DOMAIN, TAG, 'A11YCLIENT ACTION readback failed err=%{public}s', shortError(err));
      });
    }, 900);
  }

  private async readBackClick(id: number): Promise<void> {
    const element = this.pendingClick;
    if (element === undefined) {
      return;
    }
    const text = asString(await this.attr(element, 'text'));
    hilog.info(DOMAIN, TAG, 'A11YCLIENT ACTION after id=%{public}d text=%{public}s', id, text);
    this.scheduleDump('afterClick', 200);
  }

  private async walk(
    element: AccessibilityElement | undefined,
    depth: number,
    parentId: number,
    nodes: A11yNodeView[],
    isTarget: boolean,
    clickId: number,
  ): Promise<ClickResult> {
    if (element === undefined || depth > MAX_DEPTH || nodes.length >= MAX_NODES) {
      return { clickId: clickId, clickElement: undefined };
    }
    const id = nodes.length;
    const view = await this.snapshot(element, id, parentId, depth);
    nodes.push(view);
    let nextClickId = clickId;
    let nextClickElement: AccessibilityElement | undefined = undefined;
    if (nextClickId < 0 && isTarget && view.clickable && nodeLabel(view).indexOf(CLICK_LABEL) >= 0) {
      nextClickId = id;
      nextClickElement = element;
    }
    const children = await this.readChildren(element);
    for (let i = 0; i < children.length; i++) {
      const result = await this.walk(children[i], depth + 1, id, nodes, isTarget, nextClickId);
      if (result.clickId !== nextClickId) {
        nextClickId = result.clickId;
        nextClickElement = result.clickElement;
      }
      if (nodes.length >= MAX_NODES) {
        break;
      }
    }
    return { clickId: nextClickId, clickElement: nextClickElement };
  }

  private async readChildren(element: AccessibilityElement): Promise<AccessibilityElement[]> {
    const value: ESObject = await this.attr(element, 'children');
    const children: AccessibilityElement[] = [];
    if (value === undefined || value === null) {
      return children;
    }
    try {
      const list = value as AccessibilityElement[];
      for (let i = 0; i < list.length; i++) {
        children.push(list[i]);
      }
    } catch (err) {
      return children;
    }
    return children;
  }

  private async snapshot(element: AccessibilityElement, id: number, parentId: number, depth: number): Promise<A11yNodeView> {
    const text = asString(await this.attr(element, 'text'));
    const a11yText = asString(await this.attr(element, 'accessibilityText'));
    const description = asString(await this.attr(element, 'description'));
    const contents = this.firstContent(await this.attr(element, 'contents'));
    const hintText = asString(await this.attr(element, 'hintText'));
    const role: string = await this.roleOf(element);
    const node: A11yNodeView = {
      id: id,
      parentId: parentId,
      depth: depth,
      role: role,
      text: text,
      label: '',
      description: description,
      a11yText: a11yText,
      contents: contents,
      hintText: hintText,
      resourceName: asString(await this.attr(element, 'resourceName')),
      inspectorKey: asString(await this.attr(element, 'inspectorKey')),
      clickable: asBool(await this.attr(element, 'clickable')),
      longClickable: asBool(await this.attr(element, 'longClickable')),
      focusable: asBool(await this.attr(element, 'focusable')),
      a11yFocused: asBool(await this.attr(element, 'accessibilityFocused')),
      focused: asBool(await this.attr(element, 'isFocused')),
      checkable: asBool(await this.attr(element, 'checkable')),
      checked: asBool(await this.attr(element, 'checked')),
      selected: asBool(await this.attr(element, 'selected')),
      scrollable: asBool(await this.attr(element, 'scrollable')),
      visible: asBool(await this.attr(element, 'isVisible')),
      enabled: asBool(await this.attr(element, 'isEnable')),
      editable: asBool(await this.attr(element, 'editable')),
      windowId: asNumber(await this.attr(element, 'windowId')),
      rect: asRect(await this.attr(element, 'rect')),
    };
    node.label = nodeLabel(node);
    return node;
  }

  private async roleOf(element: AccessibilityElement): Promise<string> {
    const componentType = asString(await this.attr(element, 'componentType'));
    const customType = asString(await this.attr(element, 'customComponentType'));
    if (customType.length > 0) {
      return componentType + '(' + customType + ')';
    }
    return componentType;
  }

  private firstContent(value: ESObject): string {
    if (value === undefined || value === null) {
      return '';
    }
    try {
      const list = value as string[];
      if (list.length > 0 && typeof list[0] === 'string') {
        return list[0] as string;
      }
    } catch (err) {
      return '';
    }
    return '';
  }

  private async attr(element: AccessibilityElement, name: ElementAttributeKeys): Promise<ESObject> {
    try {
      const value: ESObject = await element.attributeValue(name);
      return value;
    } catch (err) {
      return undefined;
    }
  }

  private writeDump(path: string, content: string): number {
    try {
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      const written = fileIo.writeSync(file.fd, content);
      fileIo.closeSync(file);
      return written;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'A11YCLIENT write failed path=%{public}s err=%{public}s', path, shortError(err));
      return -1;
    }
  }
}

interface ClickResult {
  clickId: number;
  clickElement: AccessibilityElement | undefined;
}

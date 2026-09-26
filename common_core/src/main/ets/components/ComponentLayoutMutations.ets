/*
 * 组件布局的改动操作。
 *
 * 位置寻址
 * --------
 * 容器里的子组件没有身份标识 —— 桌面版的 ComponentSettings 就是个配置项，
 * 连自己的 Guid 都没有（只有组件类型的 GUID）。所以改动操作靠「哪一行、第几个」
 * 定位，传一个 ComponentSettings 引用过去等于什么都没说：同一个引用可能已被
 * 移动过，指针还在原处。
 *
 * 子列表是副本，改完必须写回
 * ------------------------
 * 容器的子组件在 JSON 上是 Settings.Children，而 Settings 是裸节点，我们不
 * 持有一份长期可写的数组。所以每次改动都是「读一份、改、再写回」。
 * 唯一例外是行的直接子列表：那是 MainWindowLineSettings.children 本身，
 * 读出来就是活数组，写回是多余的（但也无害，isContainer 为 false 时
 * setChildrenOf 什么都不做）。
 *
 * 所以下面所有操作都走 readChildren / writeChildren 这一对，不直接摸数组。
 * 漏掉写回的话，嵌套容器里的增删改会「点了没反应」，而顶层一切正常 ——
 * 因为只有顶层不需要写回。
 *
 * 移动语义：搬走不是拷贝
 * ---------------------
 * 移动用「先取出再插入」，不是复制。同一份配置出现在两个地方时，桌面版读回来
 * 也只有一份。
 *
 * 但「不是拷贝」说的是**内容**层面，不是对象身份：行的直接子列表是活数组，
 * 在这一层移动时前后拿到的是同一个对象；一旦跨进容器，走的就是「读副本 → 写回」，
 * 写回会把裸节点重新解析成新对象。所以想追踪某个组件请用它的组件类型 GUID，
 * 别拿对象引用当身份 —— 那个引用随时可能在一次写回之后指向别的实例。
 *
 * insertIndex 的含义
 * -----------------
 * 是**移动完成之后**组件在目标列表里的下标。这个定义让「同一列表内移动」和
 * 「跨列表移动」用同一套代码：如果源和目标是同一个列表，取出动作已经让目标
 * 列表少了一个元素，insertIndex 直接就是取完之后的下标；如果是不同列表，取出
 * 动作压根不影响它，insertIndex 也正好就是移动后的下标。两种情况都不需要修正。
 * 若定义成「取出之前的下标」，同一列表内就得按取出位置做偏移，那个偏移很容易
 * 在以后有人调整取出的时机时忘掉。
 *
 * 挡掉环
 * ------
 * 把容器移进自己的子孙会形成环，渲染时是无限递归，界面上表现为面板卡死。
 * 这里显式挡掉并返回 false。同理把组件移进它自己也不行。
 */

import { ComponentProfile, ComponentSettings, MainWindowLineSettings } from 'common_shared';
import { ComponentCatalog, ComponentDescriptor } from './ComponentCatalog';

/** 布局里的一个位置：哪一行、往下第几层容器、第几个。 */
export class ComponentLocation {
  /** 哪一行。 */
  lineIndex: number = 0;
  /**
   * 从该行根到目标组件的逐层下标。
   *
   * 空数组表示这一行的直接子列表（行本身就是个容器）。
   * `[0]` 表示该行的第 0 个组件；它得是容器，path 继续往下才合法。
   */
  path: number[] = [];

  static of(lineIndex: number, path: number[]): ComponentLocation {
    const out: ComponentLocation = new ComponentLocation();
    out.lineIndex = lineIndex;
    out.path = path.slice();
    return out;
  }

  static at(lineIndex: number, ...path: number[]): ComponentLocation {
    return ComponentLocation.of(lineIndex, path);
  }

  equals(other: ComponentLocation | undefined): boolean {
    if (other === undefined || this.lineIndex !== other.lineIndex ||
      this.path.length !== other.path.length) {
      return false;
    }
    for (let i: number = 0; i < this.path.length; i++) {
      if (this.path[i] !== other.path[i]) {
        return false;
      }
    }
    return true;
  }
}

export class ComponentLayoutMutations {
  // ---- 行 ------------------------------------------------------------

  /** 插入一行。index 可以等于 length（追加到最后）。 */
  static addLine(profile: ComponentProfile, index: number): boolean {
    if (index < 0 || index > profile.lines.length) {
      return false;
    }
    profile.lines.splice(index, 0, new MainWindowLineSettings());
    return true;
  }

  static removeLine(profile: ComponentProfile, index: number): boolean {
    if (index < 0 || index >= profile.lines.length) {
      return false;
    }
    profile.lines.splice(index, 1);
    return true;
  }

  /** 移动一行。to 同样可以等于 length。 */
  static moveLine(profile: ComponentProfile, from: number, to: number): boolean {
    if (from < 0 || from >= profile.lines.length || to < 0 || to > profile.lines.length) {
      return false;
    }
    const line: MainWindowLineSettings = profile.lines[from];
    profile.lines.splice(from, 1);
    profile.lines.splice(to > from ? to - 1 : to, 0, line);
    return true;
  }

  // ---- 组件 ----------------------------------------------------------

  /**
   * 加一个组件。target 为空 path 时是加到行的直接子列表。
   *
   * 目标不是容器时返回 false：静默加到行首的话用户以为组件进了某个容器，
   * 结果它出现在行的最前面，而行里原本就有别的组件，位置完全对不上。
   */
  static addComponent(profile: ComponentProfile, target: ComponentLocation,
    component: ComponentSettings): boolean {
    const children: ComponentSettings[] | undefined =
      ComponentLayoutMutations.readChildren(profile, target.lineIndex, target.path);
    if (children === undefined) {
      return false;
    }
    children.push(component);
    return ComponentLayoutMutations.writeChildren(profile, target.lineIndex, target.path, children);
  }

  static removeComponent(profile: ComponentProfile, target: ComponentLocation): boolean {
    if (target.path.length === 0) {
      return false;
    }
    const parentPath: number[] = target.path.slice(0, target.path.length - 1);
    const children: ComponentSettings[] | undefined =
      ComponentLayoutMutations.readChildren(profile, target.lineIndex, parentPath);
    if (children === undefined) {
      return false;
    }
    const index: number = target.path[target.path.length - 1];
    if (index < 0 || index >= children.length) {
      return false;
    }
    children.splice(index, 1);
    return ComponentLayoutMutations.writeChildren(profile, target.lineIndex, parentPath, children);
  }

  /**
   * 把一个组件移进 to 这个容器，落在移动后的第 insertIndex 位。
   *
   * 搬的是同一份配置内容，不产生副本。移进自己的子孙（含自己）返回 false，见文件头。
   *
   * **失败时布局必须原样不变。** 这条是踩出来的：早先的写法是「先从源里取出来，
   * 再看目标存不存在」，于是目标非法时函数返回 false，源里那个组件却已经被拿掉
   * 了 —— 界面上表现为组件凭空消失，而返回值明明说了没成功。所以下面三处都要
   * 能把源复原：目标预检、取出写回失败、插入写回失败。
   *
   * **from 与 to 都按移动前的那棵树理解。** 目标预检在移动前做，实际插入在移动
   * 后做：同一列表内移动时取出动作会改变目标列表的内容，只有取出之后再读目标，
   * insertIndex 才是「移动后的下标」。to 指向的容器如果在移动中挪了位置（例如
   * from 是 [0] 而 to 是 [1,0]），那就按移动后的位置解析；解析不到时按失败处理
   * 并把组件放回原处。
   */
  static moveComponent(profile: ComponentProfile, from: ComponentLocation,
    to: ComponentLocation, insertIndex: number): boolean {
    if (from.path.length === 0) {
      return false;
    }
    if (ComponentLayoutMutations.isSameOrBelow(from, to)) {
      return false;
    }
    if (insertIndex < 0) {
      return false;
    }
    // 目标先探一次。少这一步的话，上面说的「组件凭空消失」就会真实发生。
    if (ComponentLayoutMutations.readChildren(profile, to.lineIndex, to.path) === undefined) {
      return false;
    }
    const parentPath: number[] = from.path.slice(0, from.path.length - 1);
    const fromChildren: ComponentSettings[] | undefined =
      ComponentLayoutMutations.readChildren(profile, from.lineIndex, parentPath);
    if (fromChildren === undefined) {
      return false;
    }
    const index: number = from.path[from.path.length - 1];
    if (index < 0 || index >= fromChildren.length) {
      return false;
    }
    const moved: ComponentSettings = fromChildren[index];
    fromChildren.splice(index, 1);
    if (!ComponentLayoutMutations.writeChildren(profile, from.lineIndex, parentPath, fromChildren)) {
      ComponentLayoutMutations.restore(profile, from.lineIndex, parentPath, fromChildren, index, moved);
      return false;
    }
    const toChildren: ComponentSettings[] | undefined =
      ComponentLayoutMutations.readChildren(profile, to.lineIndex, to.path);
    if (toChildren === undefined) {
      ComponentLayoutMutations.restore(profile, from.lineIndex, parentPath, fromChildren, index, moved);
      return false;
    }
    const at: number = insertIndex > toChildren.length ? toChildren.length : insertIndex;
    toChildren.splice(at, 0, moved);
    if (!ComponentLayoutMutations.writeChildren(profile, to.lineIndex, to.path, toChildren)) {
      // 目标侧那一份要么是活数组（写回必成），要么是副本（写回失败时树没被动过），
      // 所以这里只需要把源复原。
      ComponentLayoutMutations.restore(profile, from.lineIndex, parentPath, fromChildren, index, moved);
      return false;
    }
    return true;
  }

  /** 同一父下相邻两个组件互换。location 必须指向一个组件（path 非空）。 */
  static swapSibling(profile: ComponentProfile, location: ComponentLocation): boolean {
    if (location.path.length === 0) {
      return false;
    }
    const parentPath: number[] = location.path.slice(0, location.path.length - 1);
    const children: ComponentSettings[] | undefined =
      ComponentLayoutMutations.readChildren(profile, location.lineIndex, parentPath);
    if (children === undefined) {
      return false;
    }
    const index: number = location.path[location.path.length - 1];
    if (index < 0 || index + 1 >= children.length) {
      return false;
    }
    const a: ComponentSettings = children[index];
    children[index] = children[index + 1];
    children[index + 1] = a;
    return ComponentLayoutMutations.writeChildren(profile, location.lineIndex, parentPath, children);
  }

  // ---- 内部 ----------------------------------------------------------

  /**
   * 读某个容器的子列表。位置不存在或不是容器时返回 undefined。
   *
   * path 为空返回行的活数组 —— 改它就改了，但仍然要调 writeChildren 才算完整
   * 的一步（writeChildren 对活数组是 no-op，两种情况都安全）。
   */
  private static readChildren(profile: ComponentProfile, lineIndex: number,
    path: number[]): ComponentSettings[] | undefined {
    if (lineIndex < 0 || lineIndex >= profile.lines.length) {
      return undefined;
    }
    let children: ComponentSettings[] = profile.lines[lineIndex].children;
    for (const index of path) {
      if (index < 0 || index >= children.length) {
        return undefined;
      }
      const node: ComponentSettings = children[index];
      const descriptor: ComponentDescriptor | undefined = ComponentCatalog.find(node.id);
      if (descriptor === undefined || !descriptor.isContainer) {
        return undefined;
      }
      children = ComponentCatalog.childrenOf(node);
    }
    return children;
  }

  /** 把子列表写回。path 为空表示行的直接子列表，已经就地生效，返回 true。 */
  private static writeChildren(profile: ComponentProfile, lineIndex: number, path: number[],
    children: ComponentSettings[]): boolean {
    if (lineIndex < 0 || lineIndex >= profile.lines.length) {
      return false;
    }
    if (path.length === 0) {
      return true;
    }
    let cursor: ComponentSettings[] = profile.lines[lineIndex].children;
    for (let i: number = 0; i < path.length; i++) {
      const index: number = path[i];
      if (index < 0 || index >= cursor.length) {
        return false;
      }
      const node: ComponentSettings = cursor[index];
      if (i === path.length - 1) {
        ComponentCatalog.setChildrenOf(node, children);
        return true;
      }
      cursor = ComponentCatalog.childrenOf(node);
    }
    return false;
  }

  /** 把取出来的组件放回原位，用于移动失败时的回滚。 */
  private static restore(profile: ComponentProfile, lineIndex: number, path: number[],
    children: ComponentSettings[], index: number, moved: ComponentSettings): void {
    children.splice(index, 0, moved);
    ComponentLayoutMutations.writeChildren(profile, lineIndex, path, children);
  }

  /** from 是否就是 to、或在 to 之下。 */
  private static isSameOrBelow(from: ComponentLocation, to: ComponentLocation): boolean {
    if (from.lineIndex !== to.lineIndex) {
      return false;
    }
    if (from.path.length > to.path.length) {
      return false;
    }
    for (let i: number = 0; i < from.path.length; i++) {
      if (from.path[i] !== to.path[i]) {
        return false;
      }
    }
    return true;
  }
}

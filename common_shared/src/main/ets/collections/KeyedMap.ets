/*
 * 保序键值映射。
 *
 * 对应桌面版的 ObservableDictionary<Guid, T> 与 ObservableDictionary<DateTime, T>。
 * 两者在 JSON 上都是「键为字符串的对象」，且键序即插入序（System.Text.Json 按
 * 枚举顺序写出），因此统一用字符串键承载，Guid / DateTime 的字符串化由调用方负责。
 *
 * 底层用 Map：其迭代顺序即插入顺序，可直接保证字节级往返。
 *
 * 可变性约定：变更走「整体替换」而非就地修改（ArkUI V2 状态管理需要），
 * 故本类提供 clone()，不提供逐项的通知机制。
 */

export class KeyedMap<V> {
  private map: Map<string, V> = new Map<string, V>();

  constructor() {
  }

  static of<V>(): KeyedMap<V> {
    return new KeyedMap<V>();
  }

  get size(): number {
    return this.map.size;
  }

  get isEmpty(): boolean {
    return this.map.size === 0;
  }

  has(key: string): boolean {
    return this.map.has(key);
  }

  /** 读取；不存在返回 undefined。 */
  tryGet(key: string): V | undefined {
    return this.map.get(key);
  }

  /** 读取；不存在返回 fallback。 */
  getOrDefault(key: string, fallback: V): V {
    const found: V | undefined = this.map.get(key);
    return found === undefined ? fallback : found;
  }

  /** 写入；键已存在时保留原有位置（与 JsonObject.set 行为一致）。 */
  set(key: string, value: V): void {
    this.map.set(key, value);
  }

  delete(key: string): boolean {
    return this.map.delete(key);
  }

  clear(): void {
    this.map.clear();
  }

  /** 按插入序遍历键。 */
  keys(): string[] {
    const out: string[] = [];
    this.map.forEach((value: V, key: string) => {
      out.push(key);
    });
    return out;
  }

  /** 按插入序遍历值。 */
  values(): V[] {
    const out: V[] = [];
    this.map.forEach((value: V) => {
      out.push(value);
    });
    return out;
  }

  /** 按插入序遍历键值对，避免解构：回调收到 (value, key)。 */
  forEach(action: (value: V, key: string) => void): void {
    this.map.forEach((value: V, key: string) => {
      action(value, key);
    });
  }

  /** 浅拷贝，键序保持不变。 */
  clone(): KeyedMap<V> {
    const out: KeyedMap<V> = new KeyedMap<V>();
    this.map.forEach((value: V, key: string) => {
      out.set(key, value);
    });
    return out;
  }

  /** 由键值对数组构造。 */
  static fromEntries<V>(entries: KeyedMapEntry<V>[]): KeyedMap<V> {
    const out: KeyedMap<V> = new KeyedMap<V>();
    for (const entry of entries) {
      out.set(entry.key, entry.value);
    }
    return out;
  }
}

export class KeyedMapEntry<V> {
  key: string;
  value: V;

  constructor(key: string, value: V) {
    this.key = key;
    this.value = value;
  }
}

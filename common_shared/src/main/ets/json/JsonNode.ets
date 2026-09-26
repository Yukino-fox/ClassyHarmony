/*
 * JSON 节点模型。
 *
 * 为什么不用 JSON.parse / JSON.stringify 直接收发：
 * 1. ArkTS 禁止显式 any / unknown，JSON.parse 返回 any，无法在不引入断言的前提下做类型收窄。
 * 2. 桌面版（System.Text.Json）按 C# 属性声明顺序输出，键顺序是字节级往返的一部分，
 *    交由 JS 对象会丢失插入顺序保证。
 * 3. C# 的 int 与 double 需分别格式化，且 Guid / TimeSpan / Color 均有专用字面量格式。
 * 4. AttachedObjects、ActionItem.Settings 这类多态裸 JSON 需要原样透传，
 *    保留数字原始字面量可使其往返完全无损。
 *
 * 本节点树同时承担「解析」「类型化读取」「无损透传」「精确写出」四职。
 */

/** JSON 节点基类。 */
export abstract class JsonNode {
}

/** 对象成员：键名 + 节点。成员顺序即输出顺序。 */
export class JsonMember {
  name: string;
  value: JsonNode;

  constructor(name: string, value: JsonNode) {
    this.name = name;
    this.value = value;
  }
}

/** JSON 对象。成员保序，禁止重复键。 */
export class JsonObject extends JsonNode {
  private members: JsonMember[] = [];

  /** 追加成员。若键已存在则原地替换（保持原有位置），不会追加到末尾。 */
  set(name: string, value: JsonNode): void {
    for (const m of this.members) {
      if (m.name === name) {
        m.value = value;
        return;
      }
    }
    this.members.push(new JsonMember(name, value));
  }

  /** 追加成员，但仅当值为 null 时跳过。用于复刻 JsonIgnoreCondition.WhenWritingNull。 */
  setIfNotNull(name: string, value: JsonNode | undefined): void {
    if (value !== undefined) {
      this.set(name, value);
    }
  }

  tryGet(name: string): JsonNode | undefined {
    for (const m of this.members) {
      if (m.name === name) {
        return m.value;
      }
    }
    return undefined;
  }

  has(name: string): boolean {
    return this.tryGet(name) !== undefined;
  }

  get count(): number {
    return this.members.length;
  }

  at(index: number): JsonMember | undefined {
    if (index < 0 || index >= this.members.length) {
      return undefined;
    }
    return this.members[index];
  }

  /** 只读遍历用的成员数组快照。 */
  entries(): JsonMember[] {
    return this.members;
  }
}

/** JSON 数组。 */
export class JsonArray extends JsonNode {
  private items: JsonNode[] = [];

  push(value: JsonNode): void {
    this.items.push(value);
  }

  get count(): number {
    return this.items.length;
  }

  at(index: number): JsonNode | undefined {
    if (index < 0 || index >= this.items.length) {
      return undefined;
    }
    return this.items[index];
  }

  values(): JsonNode[] {
    return this.items;
  }
}

/** JSON 字符串。 */
export class JsonString extends JsonNode {
  value: string;

  constructor(value: string) {
    super();
    this.value = value;
  }
}

/**
 * JSON 数字。
 *
 * 同时保留原始字面量与数值：未修改的字段原样回写，保证往返无损；
 * 修改过的字段走 value 重新格式化。
 */
export class JsonNumber extends JsonNode {
  raw: string;
  value: number;

  constructor(raw: string, value: number) {
    super();
    this.raw = raw;
    this.value = value;
  }

  static of(value: number): JsonNumber {
    return new JsonNumber(JsonWriterFormat.number(value), value);
  }

  /** 整数专用：保证不带小数点或指数形式。 */
  static ofInt(value: number): JsonNumber {
    return new JsonNumber(Math.trunc(value).toFixed(0), Math.trunc(value));
  }
}

/** JSON 布尔。 */
export class JsonBoolean extends JsonNode {
  value: boolean;

  constructor(value: boolean) {
    super();
    this.value = value;
  }
}

/** JSON null。 */
export class JsonNull extends JsonNode {
  constructor() {
    super();
  }
}

/** 数字字面量格式化，规则对齐 .NET 的最短往返语义。 */
export class JsonWriterFormat {
  /**
   * 整数值不带小数点（对齐 System.Text.Json：double 14.0 写作 14）。
   * 非整数用 JS 最短往返表示；指数形式按 .NET 风格大写 E 并补正号。
   */
  static number(value: number): string {
    if (Number.isNaN(value) || !Number.isFinite(value)) {
      // .NET 默认写出 NaN / Infinity 为非法 JSON 字面量；此处退化为 0 以保证输出始终可解析。
      return '0';
    }
    if (Number.isInteger(value) && Math.abs(value) < 1e21) {
      return value.toFixed(0);
    }
    const s = String(value);
    if (s.indexOf('e') < 0 && s.indexOf('E') < 0) {
      return s;
    }
    // 1e+21 -> 1E+21，与 .NET double.ToString() 的指数形式对齐
    return s.replace('e', 'E').replace('E+', 'E+').replace('E-', 'E-');
  }
}

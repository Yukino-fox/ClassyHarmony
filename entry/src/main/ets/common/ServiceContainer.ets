/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 手写服务容器。
 *
 * 不用反射、不用装饰器：显式工厂注册，类型在调用点可见。
 * ArkTS 不支持运行期扫描类路径，注解式 IoC 也无处落脚，
 * 显式注册反而更直白，出错时栈也更清楚。
 *
 * 生命周期刻意保持简单：整个进程一个实例，注册一次。
 * 小组件的 FormExtensionAbility 是独立运行时，它自己建一个容器，
 * 不与主应用共享 —— 引擎本身无静态可变状态，所以这样切是安全的。
 */

export class ServiceContainer {
  private factories: Map<string, () => Object> = new Map();
  private instances: Map<string, Object> = new Map();

  /**
   * 注册一个服务的工厂。工厂在首次 resolve 时才调用，之后缓存实例。
   *
   * key 必须全局唯一，重名直接抛错而不是静默覆盖 ——
   * 静默覆盖会让「拿到的是哪个实现」变成玄学。
   *
   * 泛型加了 `extends Object` 约束而不是留空：容器内部统一按 Object 存，
   * 无约束的 T 在 ArkTS 下不被视为可赋给 Object，工厂存不进去。
   */
  register<T extends Object>(key: string, factory: () => T): void {
    if (this.factories.has(key)) {
      throw new Error(`服务重复注册: ${key}`);
    }
    const boxed: () => Object = (): Object => factory();
    this.factories.set(key, boxed);
  }

  /**
   * 注册一个已经建好的单例。用于那些构造无副作用、不值得包工厂的服务。
   */
  registerValue<T extends Object>(key: string, value: T): void {
    if (this.factories.has(key)) {
      throw new Error(`服务重复注册: ${key}`);
    }
    this.factories.set(key, (): Object => value);
    this.instances.set(key, value);
  }

  /**
   * 取服务。首次调用执行工厂并缓存。
   */
  resolve<T extends Object>(key: string): T | undefined {
    if (this.instances.has(key)) {
      return this.instances.get(key) as T;
    }
    const factory: (() => Object) | undefined = this.factories.get(key);
    if (factory === undefined) {
      return undefined;
    }
    const created: Object = factory();
    this.instances.set(key, created);
    return created as T;
  }

  /** 取服务或抛出，语义上「必须有」。用于启动期装配。 */
  require<T extends Object>(key: string): T {
    const value: T | undefined = this.resolve<T>(key);
    if (value === undefined) {
      throw new Error(`服务未注册: ${key}`);
    }
    return value;
  }

  has(key: string): boolean {
    return this.factories.has(key);
  }
}

/** 服务键。集中定义，避免各处硬编码字符串写错。 */
export class ServiceKeys {
  static readonly CLOCK: string = 'clock';
  static readonly PROFILE_REPO: string = 'profileRepository';
  static readonly ENGINE_SETTINGS: string = 'engineSettings';
}

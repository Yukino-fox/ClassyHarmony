/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 天气缓存（entry 侧）：weather.json。
 *
 * 为什么不复用 settings.json 里的 LastWeatherInfo
 * ----------------------------------------------
 * 桌面版把最近一次天气直接塞在 Settings.LastWeatherInfo 里一起落盘。这里不
 * 那么做，三条理由：
 *  1. AppPreferences.put 只收标量。LastWeatherInfo 是一棵嵌套对象，塞进去要
 *     单独给 AppPreferences 开一条「写任意节点」的口子，而那条口子一旦存在，
 *     就会有人拿它写别的嵌套结构，扁平键的约定就烂了。
 *  2. 天气 5 分钟刷新一次。写进 settings.json 意味着每 5 分钟把整个设置文件
 *     读出来、parse 一遍、再整份重写一遍（还是原子写 + rename），而里面
 *     99% 的键跟这次刷新毫无关系。放在独立文件里，代价只是一次小文件的写。
 *  3. 这份数据本来就是**缓存**：丢了就是「等下次刷新」，没有不可再生性。
 *     设置文件被写坏是不可接受的，缓存文件被写坏无所谓。
 *
 * 桌面版 settings.json 里那份 LastWeatherInfo 健在，本端不读也不写 —— 所以
 * 它不会因为本端运行而被改掉。写出时（别的键触发的重写）也会原样保留。
 *
 * 原子写
 * ------
 * 与 AppPreferences 同一套：临时文件 + rename。天气是 5 分钟一次的后台写，
 * 与「用户正在改设置」可能撞在同一时刻（同一个进程，单线程事件循环，其实不会
 * 真并发，但写一半被杀会留下半截 JSON）。半截 JSON 的解析结果是空天气，表现
 * 是「天气组件突然空了一下又好了」，不值得冒。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import {
  JsonNode,
  JsonObject,
  JsonReader,
  JsonWriter,
  WeatherInfo
} from 'common_shared';

const FILE_NAME: string = 'weather.json';
const TEMP_NAME: string = 'weather.json.tmp';

export class WeatherStore {
  private readonly dir: string;

  constructor(context: common.Context) {
    this.dir = context.filesDir;
  }

  private path(): string {
    return `${this.dir}/${FILE_NAME}`;
  }

  /**
   * 读缓存。
   *
   * 文件不存在、被截断、不是对象 —— 三种都返回空 WeatherInfo（`hasData()` 为
   * false，组件会显示「天气数据还没取到」）。不抛：抛了的话天气服务起不来，
   * 而「缓存坏了」的表现应该是「等下次刷新」，不是「天气功能整个没了」。
   */
  load(): WeatherInfo {
    try {
      const content: string = fs.readTextSync(this.path());
      const node: JsonNode = JsonReader.parse(content);
      if (node instanceof JsonObject) {
        return WeatherInfo.parse(node);
      }
    } catch (error) {
      // 读不到就是没有缓存，不是错误。
    }
    return new WeatherInfo();
  }

  /** 整份覆盖写。 */
  save(info: WeatherInfo): void {
    const temp: string = `${this.dir}/${TEMP_NAME}`;
    const file: fs.File = fs.openSync(temp,
      fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JsonWriter.writeCompact(info.toJson()), { encoding: 'utf-8' });
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(temp, this.path());
  }

  /** 删掉缓存。「清缓存」类操作会用到；当前没有调用点，但留着比删掉安全。 */
  clear(): void {
    try {
      fs.unlinkSync(this.path());
    } catch (error) {
      // 本来就不存在。
    }
  }
}

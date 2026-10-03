/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 天气取数服务（entry 侧）。对应桌面版 `Services/WeatherService.cs` 的
 * `QueryWeatherWithResultAsync` 与 `UpdateTimerOnTick`。
 *
 * 分工
 * ----
 * 预警的排除与去重、五条天气规则、码表展开、简报合成全在 common_core（有
 * 325 条用例在盯）。这里只做四件事：
 *   - 请求小米天气 API（HTTP + JSON）；
 *   - 设备定位（@kit.LocationKit）与城市精度降级；
 *   - 5 分钟定时刷新；
 *   - 把结果整份替换进进程内的 `WeatherSnapshot`，并落 weather.json 缓存。
 *
 * 必须是进程内单例
 * --------------
 * 快照与定时器是跨调用状态：面板、规则求值（提醒/自动化）读的必须是同一份
 * 快照，各自建一份会出现「面板已刷新、规则还是旧的」这种最难查的不一致。
 * 走模块级实例，与 ExactTimeService / SpeechService 同一个路子。
 *
 * 与桌面版的一处刻意分歧：失败不清空
 * --------------------------------
 * 桌面版 `Settings.LastWeatherInfo = info` 只在成功那一步发生，失败路径不动
 * 它；这里照抄。任何一步失败都保留上一次成功的快照（`isRefreshed` 只反映
 * 「本轮进程内取到过没有」），绝不把 info 清空 —— 清空的话组件会从「显示旧
 * 温度」跳成「天气数据还没取到」，而用户只是进了电梯。
 *
 * 与桌面版的第二处刻意分歧：定位失败不阻塞
 * --------------------------------------
 * 桌面版定位失败只记日志、继续用旧坐标。这里照抄，但额外把「定位权限没给」
 * 也归到这条路径：拿不到定位就拿配置里的坐标（默认 0,0）继续走城市查询。
 * 鸿蒙的运行时权限弹窗很可能被拒（用户不知道为什么要给定位），拒了之后
 * 「天气整个不可用」是不可接受的降级。
 */

import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { geoLocationManager } from '@kit.LocationKit';
import {
  AppPreferences,
  PrefKeys,
  DEFAULT_CITY_ID
} from '../common/AppPreferences';
import { WeatherStore } from './WeatherStore';
import { t, tf } from 'common_core';
import { filterWeatherAlerts, WeatherSnapshot } from 'common_core';
import {
  CityInfo,
  DateTimeValue,
  JsonArray,
  JsonNode,
  JsonObject,
  JsonReader,
  WeatherInfo
} from 'common_shared';

const DOMAIN: number = 0x0000;
const TAG: string = 'WeatherService';

/** 刷新周期：5 分钟，与桌面版 `UpdateTimer.Interval` 一致。 */
const REFRESH_MS: number = 5 * 60 * 1000;

/** 网络超时（毫秒）。天气接口在没网时会挂很久，给个上限。 */
const HTTP_TIMEOUT_MS: number = 15000;

/** 城市查询的精度档位，从高到低。对应桌面版 `new[] { 4, 3, 2, 1, 0 }`。 */
const PRECISIONS: number[] = [4, 3, 2, 1, 0];

/** 自动定位最多保留的小数位（桌面版 `Math.Round(pos.Longitude, 4)`）。 */
const LOCATION_PRECISION: number = 4;

/** 城市解析结果。 */
interface CityResolution {
  locationKey: string;
  /** 纬度字符串（小米接口要的是字符串，不是数字）。 */
  latitude: string;
  /** 经度字符串。 */
  longitude: string;
}

/** 定位结果。 */
interface GeoPoint {
  longitude: number;
  latitude: number;
}

export class WeatherService {
  private readonly prefs: AppPreferences;
  private readonly store: WeatherStore;
  private readonly context: common.UIAbilityContext;

  /** 当前快照。info 可能来自本轮取数，也可能是启动时读回的缓存。 */
  private current: WeatherSnapshot = new WeatherSnapshot();

  private timerId: number = -1;
  /** 防止并发刷新：定时器与「立即刷新」按钮可能撞在一起。 */
  private refreshing: boolean = false;
  /** 本轮进程内是否已经取过设备位置。对应桌面版 `IsPosUpdated`。 */
  private posUpdated: boolean = false;
  /** 是否已申请过定位权限。只申请一次，避免反复弹窗。 */
  private locationPermissionAsked: boolean = false;

  /** 最近一次刷新的错误文案。空串表示上一次成功。 */
  private lastError: string = '';
  /** 定位降级到的精度位数。只在降级时 >= 0，用于状态文案。 */
  private degradedPrecision: number = -1;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.prefs = new AppPreferences(context);
    this.store = new WeatherStore(context);
  }

  // ------------------------------------------------------------ 读

  /** 当前快照，可直接喂给规则求值 / 面板。 */
  snapshot(): WeatherSnapshot {
    return this.current;
  }

  /** 最近一次的天气（可能来自缓存）。 */
  lastInfo(): WeatherInfo {
    return this.current.info;
  }

  /** 本轮进程内是否成功取到过天气。 */
  isRefreshed(): boolean {
    return this.current.isRefreshed;
  }

  /** 最近一次失败的文案。空串表示没有失败。 */
  errorText(): string {
    return this.lastError;
  }

  /** 定位被降到几位小数。-1 表示没有降级（或没走定位）。 */
  locationPrecision(): number {
    return this.degradedPrecision;
  }

  /**
   * 状态文案。给设置页显示。
   *
   * 优先级：错误 > 没数据 > 有数据。都带上「更新于什么时候」，因为天气是
   * 唯一一个「显示的是缓存、可能与现实不符」的模块，不给时间用户没法判断
   * 该不该手动刷新。
   */
  statusText(): string {
    if (this.lastError.length > 0) {
      return tf('ws_last_refresh_failed', this.lastError);
    }
    if (!this.current.info.hasData()) {
      return t('ws_no_data');
    }
    const updated: DateTimeValue = DateTimeValue.fromLocalMillis(this.current.info.updateTime);
    if (this.degradedPrecision >= 0) {
      return tf('ws_updated_at_degraded', updated.toString(), `${this.degradedPrecision}`);
    }
    return tf('ws_updated_at', updated.toString());
  }

  // ------------------------------------------------------------ 生命周期

  /**
   * 启动：读缓存 + 起定时器 + 立刻刷一次。
   *
   * 幂等，可在 onForeground 里反复调。缓存先读进来：这样重启后、本轮还没
   * 联网成功之前，天气组件显示的是上次的温度而不是「天气数据还没取到」。
   */
  start(): void {
    if (this.current.info.updateTime === 0) {
      this.current.info = this.store.load();
    }
    if (this.timerId < 0) {
      this.timerId = setInterval((): void => {
        void this.refresh();
      }, REFRESH_MS) as number;
    }
    void this.refresh();
  }

  /** 停掉定时器。已经停过是空操作。 */
  stop(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  /** 立即刷新一次。设置页的「立即刷新」按钮走这里。 */
  async refreshNow(): Promise<void> {
    await this.refresh();
  }

  // ------------------------------------------------------------ 刷新

  /**
   * 刷新一次。
   *
   * 永不抛异常，理由同 ExactTimeService：调用方是定时器与生命周期回调，抛
   * 出去只会变成没人看的未处理 Promise 拒绝。失败全部收进 `lastError`。
   */
  private async refresh(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    try {
      await this.doRefresh();
    } catch (error) {
      this.lastError = `${error}`;
      hilog.error(DOMAIN, TAG, 'refresh failed: %{public}s', this.lastError);
    } finally {
      this.refreshing = false;
    }
  }

  private async doRefresh(): Promise<void> {
    const schema: string = this.prefs.getBoolean(PrefKeys.NO_TLS_WEATHER_REQUESTS, false)
      ? 'http' : 'https';

    await this.maybeUpdatePosition();

    const city: CityResolution | undefined = await this.resolveCity(schema);
    if (city === undefined) {
      this.lastError = t('ws_city_failed');
      return;
    }

    const info: WeatherInfo | undefined = await this.fetchWeather(schema, city);
    if (info === undefined) {
      this.lastError = t('ws_fetch_failed');
      return;
    }

    // 桌面版的顺序：先排除、再去重（filterWeatherAlerts 一次做完两件）。
    // 必须在落盘**之前**做 —— 桌面版写进 Settings.LastWeatherInfo 的也是过滤后
    // 的那份，本端要保持「缓存里的 alerts 与桌面版缓存里的 alerts 同形」。
    const exclusions: string[] = this.prefs.getStringArray(PrefKeys.EXCLUDED_WEATHER_ALERTS);
    info.alerts = filterWeatherAlerts(info.alerts, exclusions);

    this.current.info = info;
    this.current.isRefreshed = true;
    this.lastError = '';
    try {
      this.store.save(info);
    } catch (error) {
      // 缓存写失败不影响本次显示（内存里已经是新的了），最多下次启动读到旧的。
      hilog.warn(DOMAIN, TAG, 'save weather cache failed: %{public}s', `${error}`);
    }
  }

  // ------------------------------------------------------------ 定位

  /**
   * 需要时取一次设备位置。
   *
   * 两个开关都看：`AutoRefreshWeatherLocation` 决定「要不要取设备位置」，
   * `WeatherLocationSource` 决定「取到的坐标要不要用于查城市」。桌面版就是
   * 这么分的（前者管 IsPosUpdated，后者管分辨率分支）。
   */
  private async maybeUpdatePosition(): Promise<void> {
    const autoRefresh: boolean = this.prefs.getBoolean(
      PrefKeys.AUTO_REFRESH_WEATHER_LOCATION, false);
    if (this.posUpdated || !autoRefresh) {
      return;
    }
    this.posUpdated = true;

    await this.ensureLocationPermission();

    const point: GeoPoint | undefined = await this.tryGetLocation();
    if (point === undefined) {
      // 拿不到就用配置里的坐标。不是错误 —— 桌面版同样只记日志。
      hilog.info(DOMAIN, TAG, 'location unavailable, fall back to configured coordinates');
      return;
    }
    this.prefs.put(PrefKeys.WEATHER_LONGITUDE, roundTo(point.longitude, LOCATION_PRECISION));
    this.prefs.put(PrefKeys.WEATHER_LATITUDE, roundTo(point.latitude, LOCATION_PRECISION));
  }

  /**
   * 申请定位权限。只做一次。
   *
   * 用 `abilityAccessCtrl` 而不是让调用方在页面里申请：定位是天气模块的内部
   * 依赖，页面上不该出现一个「请给天气授权」的按钮 —— 用户看到它只会困惑。
   * 拒了也不阻塞：走配置坐标。
   */
  private async ensureLocationPermission(): Promise<void> {
    if (this.locationPermissionAsked) {
      return;
    }
    this.locationPermissionAsked = true;
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      await atManager.requestPermissionsFromUser(this.context,
        ['ohos.permission.APPROXIMATELY_LOCATION']);
    } catch (error) {
      hilog.info(DOMAIN, TAG, 'location permission not granted: %{public}s', `${error}`);
    }
  }

  private async tryGetLocation(): Promise<GeoPoint | undefined> {
    try {
      const location: geoLocationManager.Location = await geoLocationManager.getCurrentLocation();
      const point: GeoPoint = {
        longitude: location.longitude,
        latitude: location.latitude
      };
      return point;
    } catch (error) {
      return undefined;
    }
  }

  // ------------------------------------------------------------ 城市

  private async resolveCity(schema: string): Promise<CityResolution | undefined> {
    const source: number = this.prefs.getNumber(PrefKeys.WEATHER_LOCATION_SOURCE, 0);
    if (source === 1) {
      return await this.resolveCityByCoordinates(schema);
    }
    return await this.resolveCityById(schema);
  }

  /** `WeatherLocationSource == 0`：用配置的城市 id。 */
  private async resolveCityById(schema: string): Promise<CityResolution | undefined> {
    const cityId: string = this.prefs.getString(PrefKeys.CITY_ID, DEFAULT_CITY_ID);
    // 桌面版这一路**不**转义 cityId，照抄。
    const url: string = `${schema}://weatherapi.market.xiaomi.com/wtr-v3/location/city/info`
      + `?locationKey=${cityId}&locale=zh_cn`;
    const list: CityInfo[] | undefined = await this.getCityList(url);
    if (list === undefined || list.length === 0) {
      return undefined;
    }
    const city: CityInfo = list[0];
    if (city.locationKey !== cityId || city.locationKey.length === 0) {
      return undefined;
    }
    const resolved: CityResolution = {
      locationKey: cityId,
      latitude: city.latitude,
      longitude: city.longitude
    };
    return resolved;
  }

  /**
   * `WeatherLocationSource == 1`：用设备坐标，精度从 4 位逐步降到 0 位。
   *
   * 桌面版的降级动机：城市接口在城市中心附近返回空列表，把坐标粗化往往能
   * 落到一个更宽的区域。命中后把 CityId / CityName 写回设置 —— 于是界面上
   * 显示的城市名会跟着变，用户点开设置能看到「自动定位到 XX」。照抄。
   */
  private async resolveCityByCoordinates(schema: string): Promise<CityResolution | undefined> {
    const rawLon: number = this.prefs.getNumber(PrefKeys.WEATHER_LONGITUDE, 0.0);
    const rawLat: number = this.prefs.getNumber(PrefKeys.WEATHER_LATITUDE, 0.0);

    for (const precision of PRECISIONS) {
      const factor: number = Math.pow(10, precision);
      const candidates: GeoPoint[] = precision === 0
        ? [{ longitude: roundTo(rawLon, 0), latitude: roundTo(rawLat, 0) }]
        : [
          // 四舍五入与直接截断各试一次：两者在正负号边界上的取整方向不同。
          { longitude: roundTo(rawLon, precision), latitude: roundTo(rawLat, precision) },
          { longitude: Math.trunc(rawLon * factor) / factor,
            latitude: Math.trunc(rawLat * factor) / factor }
        ];

      for (const candidate of candidates) {
        const url: string = `${schema}://weatherapi.market.xiaomi.com/wtr-v3/location/city/geo`
          + `?longitude=${candidate.longitude}&latitude=${candidate.latitude}&locale=zh_cn`;
        const list: CityInfo[] | undefined = await this.getCityList(url);
        if (list === undefined || list.length === 0) {
          continue;
        }
        const city: CityInfo = list[0];
        if (city.status !== 0 || city.locationKey.length === 0) {
          continue;
        }
        this.prefs.put(PrefKeys.CITY_ID, city.locationKey);
        this.prefs.put(PrefKeys.CITY_NAME, `${city.name} (${city.affiliation})`);
        this.degradedPrecision = precision;
        hilog.info(DOMAIN, TAG, 'city resolved at precision %{public}d', precision);
        const resolved: CityResolution = {
          locationKey: city.locationKey,
          latitude: `${candidate.latitude}`,
          longitude: `${candidate.longitude}`
        };
        return resolved;
      }
    }
    return undefined;
  }

  // ------------------------------------------------------------ 天气

  private async fetchWeather(schema: string,
    city: CityResolution): Promise<WeatherInfo | undefined> {
    const url: string = `${schema}://weatherapi.market.xiaomi.com/wtr-v3/weather/all`
      + `?latitude=${city.latitude}&longitude=${city.longitude}`
      + `&locationKey=${encodeURIComponent(city.locationKey)}`
      + `&days=15&appKey=weather20151024&sign=zUFJoAR2ZVrDy1vF3D07`
      + `&isGlobal=false&locale=zh_cn`;
    const text: string | undefined = await this.getText(url);
    if (text === undefined) {
      return undefined;
    }
    try {
      const node: JsonNode = JsonReader.parse(text);
      if (node instanceof JsonObject) {
        return WeatherInfo.parse(node);
      }
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'weather json parse failed: %{public}s', `${error}`);
    }
    return undefined;
  }

  // ------------------------------------------------------------ HTTP

  /**
   * GET 一个字符串。失败一律返回 undefined（永不抛）。
   *
   * 每次新建 client、用完 destroy：与 NtpClient 每次新建 socket 同一个理由，
   * 长期持有一个 HttpRequest 会占着连接与回调，而天气 5 分钟才发一次。
   */
  private async getText(url: string): Promise<string | undefined> {
    const client: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await client.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: HTTP_TIMEOUT_MS,
        readTimeout: HTTP_TIMEOUT_MS
      });
      if (response.responseCode !== 200) {
        hilog.warn(DOMAIN, TAG, 'http %{public}d for %{public}s',
          response.responseCode, url);
        return undefined;
      }
      if (typeof response.result === 'string') {
        return response.result;
      }
      return undefined;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'http request failed: %{public}s', `${error}`);
      return undefined;
    } finally {
      client.destroy();
    }
  }

  private async getCityList(url: string): Promise<CityInfo[] | undefined> {
    const text: string | undefined = await this.getText(url);
    if (text === undefined) {
      return undefined;
    }
    try {
      const node: JsonNode = JsonReader.parse(text);
      if (!(node instanceof JsonArray)) {
        return undefined;
      }
      const out: CityInfo[] = [];
      for (const item of node.values()) {
        out.push(CityInfo.parse(item));
      }
      return out;
    } catch (error) {
      return undefined;
    }
  }
}

/** 四舍五入到指定小数位。JS 的 Math.round 没有精度参数，自己乘除。 */
function roundTo(value: number, precision: number): number {
  const factor: number = Math.pow(10, precision);
  return Math.round(value * factor) / factor;
}

// ------------------------------------------------------------ 单例

let instance: WeatherService | undefined = undefined;

/**
 * 取进程内唯一的 WeatherService，没有就建一个。
 *
 * 与 ExactTimeService 同一个路子：模块级实例，不走 DI 容器 —— 天气服务的
 * 生命周期跟着 Ability（前台启、后台停），而 DI 容器里的东西是「进程级」的，
 * 放进去反而要额外管启停。
 */
export function resolveWeatherService(context: common.Context): WeatherService {
  if (instance === undefined) {
    instance = new WeatherService(context as common.UIAbilityContext);
  }
  return instance;
}

/** 丢掉单例（进程要退了，或测试要重来）。 */
export function resetWeatherService(): void {
  if (instance !== undefined) {
    instance.stop();
    instance = undefined;
  }
}

/**
 * 当前天气快照。服务还没起来时返回 undefined。
 *
 * 给「拿不到 context」的调用点用：面板 ViewModel、自动化 tick。undefined 会让
 * 五条天气规则全部判 false，与「本轮还没刷新成功」同结果 —— 这正是想要的：
 * 天气服务没起来时，规则不该凭空成立。
 */
export function currentWeatherSnapshot(): WeatherSnapshot | undefined {
  if (instance === undefined) {
    return undefined;
  }
  return instance.snapshot();
}

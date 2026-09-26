# 桌面卡片（今日课程表）

P5 的产物。核心结论：**卡片上所有能被测的推导都不在卡片里**，全部在
`common_core/view/WidgetModel.ets` 的纯函数里，Node 测试台有 120 项断言覆盖。

## 分层

```
common_core/view/WidgetModel.ets
  WidgetBuilder.build(profile, settings, now, dimension)  纯函数：算出该显示什么
  WidgetCodec.encode / decode                              自研 JSON 内核编解码
      │  ← 这一层是唯一能在装机前测的部分
      │
entry/ets/widget/EntryFormAbility.ets   扩展侧：读卡片规格、读档案、按需推送
entry/ets/widget/WidgetModelFactory.ets 读档案 → refreshDerivedState → WidgetBuilder
entry/ets/widget/TodayScheduleCard.ets  卡面：把字符串画成字
entry/ets/widget/FormWidgetService.ets  主应用侧：查卡片数、让卡片重建
```

## 三条「不报错、只是卡片空白」的坑

这三条任意一条写错，编译通过、装机通过、卡片不报任何错，只是显示字段初值。
它们是这张卡片唯一的真实失败模式，记在这里以免下次再摸一遍。

### 1. LocalStorage 实例必须是同一个

`FormBindingData` 的顶层键注入的是 **`@Entry` 参数里那个 `LocalStorage` 实例**；
`@LocalStorageProp` 读的是**它自己绑定的那个**。两个不是同一个就静默失联。

```ts
const cardStorage: LocalStorage = new LocalStorage();   // 模块级单例

@Entry(cardStorage)                                     // ← 少这一句就全盘失效
@Component
struct TodayScheduleCard {
  @LocalStorageProp('payload') payload: string = '';
}
```

### 2. 键名只能有字母数字下划线

`@LocalStorageProp('my.card.title')` 会被编译器拒绝（点号、冒号、连字符都不行）。
`payload` / `dimension` 安全。

### 3. 载荷必须是 `Record<string, Object>` 字面量

```ts
const payload: Record<string, Object> = {
  'payload': WidgetCodec.encode(model),
  'dimension': model.dimension
};
formBindingData.createFormBindingData(payload);
```

不能塞 `WidgetModel` 实例，也不能塞自定义类实例 —— `FormBindingData` 只认
「键 → 基本值」，模型需要显式编解码（`WidgetCodec` 有往返测试）。

## 其它平台约束

- **`@StorageLink` 在卡片里被编译器直接拒绝**（`11706006`「can't support form
  application」）。所以这个文件用 V1 的 `@Component` 而不是工程别处的 V2。
  `@LocalStorageProp` 在 V2 里不是一等公民，两条都是硬约束。
- **`setFormNextRefreshTime(formId, minute)` 的 minute ≥ 5**，否则 401。
  `nextRefreshMinutes` 因此被夹在 `[WIDGET_REFRESH_MIN, WIDGET_REFRESH_MAX]`（5 ~ 720）。
  顺带这条也是**不做倒计时**的原因：5 分钟粒度下倒计时必然在错。
- **`reloadAllForms(context)` 是 API 22+**，只能在 UIAbility 里调。
  `EntryFormAbility` 自己推不了 —— 它的 `FormBindingData` 通道只在扩展运行时里。
  所以「保存档案 → 卡片刷新」这条链路必须由主应用发起（`AppServices` 订阅
  `ScheduleEditorViewModel.onProfileSaved`），再由系统回调一次 `onUpdateForm`。
- **`exported: true` 是必须的**（`module.json5` 的 `extensionAbilities`）。卡片由
  系统的卡片选择器在别的应用里拉起，不导出的症状是「卡片在选择器里根本不出现，
  且没有任何报错」。

## 卡片显示什么

- **「接下来」而不是「今天全部」**：从 `end >= now` 的第一节起往后排（用**结束**
  时刻过滤，所以正在上的课必然在第一条）。
- **今天上完之后往后找 7 天**，滚到下一个有课的日子，标签换「明天」「周一」。
  不这么做的话，放学后卡片是一块空白装饰。
- **不显示倒计时**。理由见上。
- **未来那天的 `nowSeconds` 用真实当前时刻**，不能用展示那天的零点 ——
  否则「还有多久到明天第一节」会算成 32 小时，卡片一整天不更新。这是个真 bug，
  已在 `widget-driver.ts` 里加了断言守住。

## 未做的

- 卡片上没有会发 `onFormEvent` 的控件，所以 `EVENT_REFRESH` 分支目前在实践中
  不会被走到。将来加长按菜单（`FormMenu`）时在 `onAddForm` 那侧不受影响，
  直接在 `onFormEvent` 里接。
- 不用深色资源、不用毛玻璃：本工程颜色目前只有 `base` 一份，见卡片文件头注，
  P10 统一处理。

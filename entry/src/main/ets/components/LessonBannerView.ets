/*
 * Copyright (c) 2026 ClassyHarmony contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 顶部横幅：此刻的状态 + 倒计时。
 *
 * 文案全部由 ClassTableViewModel 归约好传进来，这个组件只管按 tone 取色渲染。
 * 分工是这样切的：状态到人话的映射里含引擎语义（上课中看距课间、否则看距下节课），
 * 放在 ViewModel 里能被单元测试覆盖；留在组件里就只能靠肉眼看。
 */

import { LessonBanner, BannerTone } from '../viewmodel/ClassTableViewModel';

@ComponentV2
export struct LessonBannerView {
  @Param banner: LessonBanner = new LessonBanner();

  /** 强调色：上课用主色，课间用次色，无课时回到中性。 */
  private accentColor(): ResourceColor {
    if (this.banner.tone === BannerTone.OnClass) {
      return $r('app.color.ch_accent');
    }
    if (this.banner.tone === BannerTone.Breaking) {
      return $r('app.color.ch_next');
    }
    return $r('app.color.ch_text_secondary');
  }

  build() {
    Row() {
      Column() {
        Text(this.banner.title)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.ch_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.banner.subtitle.length > 0) {
          Text(this.banner.subtitle)
            .fontSize(13)
            .fontColor($r('app.color.ch_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(16)
    .backgroundColor($r('app.color.ch_surface'))
    .border({ width: { left: 4 }, color: this.accentColor() })
  }
}

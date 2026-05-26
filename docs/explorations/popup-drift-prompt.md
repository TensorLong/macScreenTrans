# Codex prompt — 弹窗 panel.maxY 被 AppKit anchor,panel 自动向词的方向 grow

## TL;DR — 用户已经看出真相

弹窗 NSPanel 在同一次取词内,**panel.maxY 不变,panel.minY 随着 contentView 内容增多而下降**(panel.height 增大)。当 panel 配置为词上方(isAbove=true,tail 朝下),词在 panel 下方 → panel.minY 是贴近词的边 → 这种 auto-resize 直接让"下边框"压向黄/绿框,这就是用户看到的"漂浮 ~25px"。

我之前的修复方向错了:我以为只要 `reflowAnchoredFrame` 在每次 update 末尾把 `panel.minY` setFrame 回 frozen 的 `pinnedScreenY`,就能锁住贴近词的边。但 AppKit 在两次 reflow 之间会自己 grow panel.height、anchor 在 panel.maxY(物理屏幕的上边),让 panel.minY 下移。log 抓到的是 reflow 调用瞬间的 panel.frame(基本稳态 + 1 帧 1px 抖动),但截图捕获的是 reflow 之间的中间态。

**真正的修复方向**: 阻止 panel 因 contentView 内容变化而 auto-resize,而不是依赖 reflow 事后修正。

## 关键证据(已收集到的 log 数据,验证 panel.maxY 是 anchor)

```
稳态:  cur=(211.0, 659.0, 390.0, 238.0)  → maxY = 659+238 = 897
异常:  cur=(211.0, 658.0, 390.0, 239.0)  → maxY = 658+239 = 897  ← 同样的 maxY!
```

panel 自己漂的方向: maxY 不变,minY -1,height +1。这跟用户描述"上边不变,下边扩展"完全吻合(AppKit Y 向上,maxY 是屏幕物理上边)。

log 只捕获到 1 帧 1px 抖动,因为 reflow 在 update 末尾立即把 panel.minY setFrame 回 659。但用户截图捕获的是 update *内部、reflow 之前*、panel 自己已经 grow 但还没被修回的瞬间状态。瞬间 grow 的量比 log 看到的 1px 大得多(用户截图视觉差 ~25px)—— log 抓不到中间峰值。

## 任务

诊断 MacScreenTrans 翻译弹窗(NSPanel 气泡)在同一次取词流程中,从"流式中"到"完成"两个阶段之间,在用户截图里**视觉上**整体上移了约 25 像素。代码层面已经把 panel 的"贴近词的那条边"在 show 时一次性算好并锁死,后续 update 只 reflow 同一个 frame。但是 AppKit auto-resize 在两次 reflow 之间让 panel.maxY anchor、panel.minY 下移、panel.height grow。

**找出 panel 自动 grow 的真正源头并禁用之**(或重新设计让"贴近词的边"成为不可动的 anchor,无视 AppKit auto-resize)。修复后 panel 在整个流程中视觉位置必须像素级一致(允许 1 像素抖动)。

## 项目

- 路径: `/Users/longmac/sideProjects/macScreenTrans`
- 平台: macOS 14+, Swift 6, SwiftPM(无 .xcodeproj)
- 主分支: `main`
- 构建/打包: `swift build` + `scripts/package-app debug`(产物 `.build/MacScreenTrans.app`)
- 测试: `swift test`(42 个,目前全过)
- App 类型: 菜单栏后台程序,三指轻点(或 Cmd+Opt+T)触发对鼠标位置文本的取词+LLM 翻译,显示一个气泡 NSPanel(尾巴指向词)。

## 关键文件

- `Sources/MacScreenTrans/FloatingTranslationWindow.swift` — 气泡 NSPanel 控制器(`FloatingTranslationWindowController`)。show / update / reflow 的几何逻辑全在这里。
- `Sources/MacScreenTrans/AppDelegate.swift` — 取词流程编排,调用 `popup.show(anchoredTo:)` 一次,后续多次 `popup.update(text)`(流式刷新)。
- `Sources/MacScreenTrans/WordHighlightOverlay.swift` — 黄色单词高亮 NSPanel,level=`.popUpMenu`。
- `Sources/MacScreenTrans/PhraseHighlightOverlay.swift` — 绿色意群高亮 NSPanel,level=`.floating`,在第一帧 LLM 解析出 source 后才 show。

## 用户报告的现象

**同一次取词**(只触发一次三指轻点),两张截图对比:

- 截图 1 (`~/Downloads/Snipaste_2026-05-25_22-38-52.png`): 黄框 + "翻译中"弹窗。气泡尾巴尖几乎贴着黄框上沿(距离 ~1-3px)。
- 截图 2 (`~/Downloads/Snipaste_2026-05-25_22-39-12.png`): 黄框 + 绿框 + "翻译完成"弹窗,内容更长(含 `adj. 持久的;持续的` 一行)。气泡尾巴尖跟黄框上沿明显有间距(~25-30px)。

两张截图都被 Snipaste 局部圈定,**镜头不一定一致** —— 这是我提出但尚未验证的可能解释之一。

## 已实施的架构修复(背景)

在用户报告这个 bug 之前,弹窗在流式过程中确实会"漂"。我们引入了 `AnchorState`(`FloatingTranslationWindow.swift` 大约 line 43-57),在 `show(anchoredTo:)` 内一次性决定 above/below、计算 `pinnedScreenY`(贴近词的那条边的屏幕 Y)、`originX`、`maxHeight`、`tailConfig`,并冻结。后续每次 `update(_:)` 调用 `reflowAnchoredFrame(state:)`(line 291),用 frozen state 重算 newFrame,只有跟 `panel.frame` 不等时才 setFrame。geometric invariant:贴近词的那条边永远不动,body 只能向远离词的方向扩展。

实测后用户仍报告"上下浮动",于是我加了文件 log 抓现场。

## 诊断 log(已就位)

`FloatingTranslationWindow.swift` 顶部加了:

```swift
private func mstDebugLog(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    let path = "/tmp/mst-debug.log"
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
```

调用点:
1. `show(anchoredTo:)` 末尾:`[MST.show] anchored word=(x,y,w,h) isAbove=N pinY=… originX=… maxH=… screenMaxY=…`
2. `reflowAnchoredFrame` 内:`[MST.reflow] isAbove=N pinY=… maxH=… want=(x,y,w,h) cur=(x,y,w,h) setFrame=YES|no` + `after setFrame, panel.frame=(x,y,w,h)`

NSLog 已经被弃用(unified log 过滤掉 debug 级别),改用了文件 log。

## 硬数据(已收集到的 ground truth)

一次完整的"persistent"取词流程的 `/tmp/mst-debug.log`:

```
[MST.show] anchored word=(357.0,621.0,99.0,26.0) isAbove=1 pinY=659.0 originX=211.5 maxH=282.0 screenMaxY=949.0
[MST.reflow] … want=(211.5,659.0,390.0,238.0) cur=(0.0,0.0,390.0,230.0) setFrame=YES
  after setFrame, panel.frame=(211.0,659.0,390.0,238.0)
[MST.reflow] … want=(211.5,659.0,390.0,238.0) cur=(211.0,659.0,390.0,238.0) setFrame=YES
  after setFrame, panel.frame=(211.0,659.0,390.0,238.0)
[MST.reflow] … want=(211.5,659.0,390.0,238.0) cur=(211.0,658.0,390.0,239.0) setFrame=YES   ← 注意!
  after setFrame, panel.frame=(211.0,659.0,390.0,238.0)
[MST.reflow] … want=(211.5,659.0,390.0,238.0) cur=(211.0,659.0,390.0,238.0) setFrame=YES
  …(后续 ~25 次都是 cur=(211.0,659.0,390.0,238.0)
```

**panel.frame 取值分布(整个流程)**:
- `(211.0, 659.0, 390.0, 238.0)` — 出现约 27 次(稳态)
- `(211.0, 658.0, 390.0, 239.0)` — 出现 **1 次**(panel 自己在 reflow 之间漂了 1 像素,minY 下降 1,height 增加 1,被下一次 reflow 立即修回)
- `(0.0, 0.0, 390.0, 230.0)` — 出现 1 次(init 值,show 之前)

`MST.show` 全程只出现 **1 次**,确认 `show(anchoredTo:)` 没被多次调用。

**几何意义**(AppKit 屏幕坐标 Y 向上):
- word.maxY = 621 + 26 = 647(黄框上沿)
- pinnedScreenY = 659 = word.maxY + 10 (highlight overhang) + 2 (verticalGap)
- panel.minY = 659 → 尾巴尖屏幕 Y = 659
- 尾巴尖到黄框上沿距离 = 659 - 647 = **12pt,固定**

**矛盾点**: log 说 panel 物理位置整个流程稳定(除了 1 像素瞬间抖动),但用户截图看到 ~25px 的视觉位置差。1 像素 ≠ 25 像素。

## 已排除的可能性

1. `show(anchoredTo:)` 被多次调用 → log 显示只有 1 次
2. `popup.show(at:)`(error path)被意外触发 → log 没记录 show_at,且会清掉 anchorState
3. `panel.setFrame` 被其他代码路径调用 → grep 全文件,只有 2 处:`show(at:)` 和 `reflowAnchoredFrame`
4. `anchorState` 被覆盖 → 只在 `show(anchoredTo:)` 设置一次,其他地方只设 nil
5. `state.pinnedScreenY` / `state.originX` / `state.maxHeight` 在 reflow 内变化 → 都是 frozen 在 `AnchorState`(struct + let)

## 尚未验证的可能性(请逐一调查)

> 用户已经诊断出方向: panel.maxY 是 anchor、panel.height auto-grow。不要回到"镜头不一致"那种没根据的解释。下面 A 仅留作 sanity 检查,实际应聚焦 B/C 路线。

### A. 截图镜头不一致(基本已被用户排除)

仅作 sanity check。用户能直接观察到"上边不变下边扩展",这本身就是高于截图镜头变化的诊断。跳过。

### B. NSWindow 的 shadow 几何在 contentSize 内容变化时偏移

panel 启用了 `hasShadow = true`,且 `bubbleBackground.layout()` 里有 `applyMaskAndShadow()`,通过 `OpaqueBubbleFillView.layout()` 安装的 `CAShapeLayer` mask 来让 shadow 跟着 bubble path 跑。如果 mask 计算在 contentView 内容变化(sourceStack 从 hidden 变 visible、targetTextView 内容增多)时被重算,且 shadow 几何被 macOS 重新评估,弹窗的视觉中心可能漂移 —— 即使 `panel.frame` 不变。验证方法:在 `OpaqueBubbleFillView.layout()` 里 log `self.bounds`、`self.layer.bounds`、`self.layer.mask.frame`、`window.contentLayoutRect`。

### C. AutoLayout 让 contentView fittingSize 超过 panel.contentSize,NSWindow auto-resize 配合 anchoring 行为(**最可能源头**)

`bubbleBackground` 是 contentView,内部 `contentStack` 用 == 约束钉到 bubbleBackground 的 top/bottom + horizontal,scrollView 的高度约束是 `heightAnchor >= 96`,**没有上限**。流式 update 内 `targetTextView.string = parsed.target` 让 NSTextView 内容增多,NSTextView `isVerticallyResizable = true` 会 grow,scrollView 跟着 grow,contentStack 整体 fittingSize 超过 panel.contentLayoutRect —— NSWindow 在这种 AutoLayout pass 之后**会** auto-resize panel 自己,且默认 anchoring 行为是保持 top-left(macOS 默认 frame origin 在左下,top-left = (minX, maxY) 不变 → maxY 不变,minY 下降)。这跟 log + 用户描述 100% 吻合。

**重点验证 / 修复路线**:

1. 把 scrollView 改成有明确的最大高度上限(例如 `scrollView.heightAnchor <= panel.contentLayoutRect.height - 其他元素 fittingSize`),让 contentStack 总 fittingSize 永远 ≤ panel.contentSize → AutoLayout pass 不会触发 panel grow。
2. 或者关掉 `targetTextView.isVerticallyResizable`(改 false),让超长内容直接走 scrollView 滚动,而不是 NSTextView 自身 grow。NSTextView 的 textContainer 已经设置了 `widthTracksTextView = true` + `containerSize.height = .greatestFiniteMagnitude`,允许 vertical scroll。把 `isVerticallyResizable = false` 后,textContainer 的 height 由 scrollView clip view 决定,不会主动 grow。
3. 显式锁死 panel 的 contentSize:在 init 内调 `panel.contentMinSize = panel.contentMaxSize = NSSize(width: popupWidth, height: popupHeight + tailHeight)`。这是兜底,可能 *不够*(因为这些 API 主要约束 user resize,不阻止 program-driven AutoLayout resize),但值得一试。
4. 最硬的方案:把 NSWindow 的 frame 计算从"被动 anchoring"改成"主动 pin"。在 `update(_:)` 里**先 reflow 锁死 panel.frame**(用 `display: false`),**再设内容**,然后在末尾**再 reflow 一次**(用 `display: true`)修正任何 AutoLayout 引发的偏移。理论上这只能掩盖问题,真正的根因还是 contentView fittingSize 过大。

**验证用诊断 log**: 在 `update(_:)` 内三个时间点 log:
- `setStringValue` 之前: `panel.frame` / `bubbleBackground.frame` / `contentStack.fittingSize`
- `setStringValue` 之后,reflow 之前: 同上
- reflow 之后: 同上

如果中间那点 panel.frame 已经被 AppKit 改了(minY 下降、height 增加、maxY 不变),那 100% 证实路线 C。

### D. Snipaste 截图的 "副本" 文件可能跟原图不同

`~/Downloads/` 里同时有 `Snipaste_2026-05-25_22-38-52.png` 和 `Snipaste_2026-05-25_22-38-52_副本.png`,文件大小相同(62.8K/79.1K 配对),但确认是否真的 1:1 还需要 `md5` 验证。低概率,但顺便排除。

### E. tail bubble 的 path 几何在 sourceStack 显隐时漂移

`bubblePath(in:)` 用 panel-local 坐标,当 `tailConfig.edge == .bottom`,tip 在 `body.minY - tailHeight = (rect.minY + tailHeight) - tailHeight = rect.minY = 0`(panel-local)—— 这跟 contentStack layout 无关,应该不动。但 `applyTailLayout` 里:

```swift
case .bottom:
    topInset = 0
    bottomInset = baseTailHeight  // 8
```

`contentBottomConstraint?.constant = -(baseInset + bottomInset) = -(14 + 8) = -22`

这只影响 contentStack 在 bubbleBackground 内部的 layout,不影响 panel.frame。但是,如果 `tailConfig` 在两个阶段之间被无意修改了(虽然 `AnchorState.tailConfig` 是 frozen),`bubbleBackground.tailConfig` 可能被外部赋值。验证:grep `bubbleBackground.tailConfig` 的所有写入点,确认只在 show 内。

### F. 在 update() 内除了 reflow 还有别的 layout 副作用

`update(_:)` 里有 `targetTextView.string = parsed.target` + `targetTextView.scrollToEndOfDocument(nil)`,后者可能触发 scrollView 的 contentInsets 自动调整,进而触发 AutoLayout pass,**可能**在 contentView 上引起视觉变化。即使不影响 panel.frame,如果 contentView 的 bounds 被 macOS 重新对齐(stage manager / appkit pixel-align)…… 这是低概率猜测。

## 用户的明确诉求(必读)

1. **不要再去随意调 `tipClearanceFromHighlight` 这个常量值**。用户认为"固定距离"= 这个数字承诺不再改。如果定位真凶后需要调,先提议、给理由,征得同意再改。
2. 用户要求"黄框单独存在时,弹窗到黄框的距离"= "黄框 + 绿框时,弹窗到黄框/绿框的距离" —— 即流式和完成两个阶段,弹窗位置应该完全一致。
3. 不要在弹窗内容增多时让弹窗位置漂移。

## 已知边界条件

- popupHeight = 230,tailHeight = 8,total panel height = 238(固定,不随内容变)
- highlightVerticalOverhang = 2,tipClearanceFromHighlight = 8(目前值,用户暂时接受但不喜欢被任意改)
- 弹窗 level = `.popUpMenu`(101),黄框 level = `.popUpMenu`,绿框 level = `.floating`(3)。黄/弹窗在绿之上。
- 用户运行在 macOS 14+,M 系列 Mac。

## 期望产出

1. 验证路线 C(AppKit auto-resize panel.height、anchor 在 top-left/maxY)是否真的是 root cause —— 通过 update 内三阶段 log 抓 panel.frame
2. 一旦确认,实施最小修复(优先级:NSTextView isVerticallyResizable=false / scrollView height 上限 / contentMinSize=contentMaxSize 锁死,三选一或组合)
3. 修复后,流式和完成两阶段,弹窗在屏幕上的视觉位置必须**像素级一致**(允许 1 像素抖动)
4. 不要破坏现有的 42 个测试(`swift test`)
5. 不要新增大段抽象/未来扩展点;只针对这个 bug 做最小修改
6. **不要随意调 `tipClearanceFromHighlight` 常量**(用户明确要求,见下文用户诉求)

## 关键代码摘录

`reflowAnchoredFrame`(当前最关键的几何函数):

```swift
private func reflowAnchoredFrame(state: AnchorState) {
    let height = min(state.maxHeight, Self.popupHeight + Self.tailHeight)

    let originY: CGFloat
    if state.isAbove {
        originY = state.pinnedScreenY  // panel.minY pinned
    } else {
        originY = state.pinnedScreenY - height  // panel.maxY pinned
    }

    let newFrame = NSRect(
        x: state.originX,
        y: originY,
        width: Self.popupWidth,
        height: height
    )
    let before = panel.frame
    let willCall = !before.equalTo(newFrame)
    mstDebugLog(...)  // 上文 log
    if willCall {
        panel.setFrame(newFrame, display: true)
        let after = panel.frame
        mstDebugLog(...)
    }
}
```

`show(anchoredTo:)` 关键段(line 189–267):

```swift
func show(anchoredTo wordRect: NSRect, text: String) {
    let screenFrame = (NSScreen.screens.first {
        NSMouseInRect(CGPoint(x: wordRect.midX, y: wordRect.midY), $0.frame, false)
    } ?? NSScreen.main)?.visibleFrame ?? .zero

    let verticalGap: CGFloat = 2
    let edgePadding: CGFloat = 8

    let anchorRect = wordRect.insetBy(
        dx: 0,
        dy: -(Self.highlightVerticalOverhang + Self.tipClearanceFromHighlight)
    )

    let idealHeight = Self.popupHeight + Self.tailHeight
    let aboveSpace = screenFrame.maxY - (anchorRect.maxY + verticalGap) - edgePadding
    let belowSpace = (anchorRect.minY - verticalGap) - screenFrame.minY - edgePadding

    let isAbove: Bool
    if aboveSpace >= idealHeight {
        isAbove = true
    } else if belowSpace >= idealHeight {
        isAbove = false
    } else {
        isAbove = aboveSpace >= belowSpace
    }

    let pinnedScreenY: CGFloat
    let maxHeight: CGFloat
    if isAbove {
        pinnedScreenY = anchorRect.maxY + verticalGap
        maxHeight = max(idealHeight, aboveSpace)
    } else {
        pinnedScreenY = anchorRect.minY - verticalGap
        maxHeight = max(idealHeight, belowSpace)
    }

    // … originX / tailX 计算省略 …

    bubbleBackground.tailConfig = tailConfig
    anchorState = AnchorState(
        isAbove: isAbove,
        pinnedScreenY: pinnedScreenY,
        originX: originX,
        maxHeight: maxHeight,
        tailConfig: tailConfig
    )

    update(text)  // 触发 reflowAnchoredFrame
    panel.orderFrontRegardless()
    dismissArmedAt = Date().addingTimeInterval(0.25)
}
```

## 调查建议(给 Codex 自己评估,不是必走)

1. 读 `FloatingTranslationWindow.swift` 全文(尤其 `BubbleBackgroundView` 和 `OpaqueBubbleFillView` 的 layout / draw / mask 部分)
2. 读 `AppDelegate.swift` line 166–358(`handleThreeFingerTap` 全流程)
3. 读 `WordHighlightOverlay.swift` 和 `PhraseHighlightOverlay.swift` 确认它们不会回调影响 popup
4. 看完代码后,如果还没找到,自己加更多文件 log(在 `reflowAnchoredFrame` 内 log `panel.contentLayoutRect` / `bubbleBackground.frame` / `bubbleBackground.bounds` / `(panel.contentView as? BubbleBackgroundView)?.fillView?.frame`)
5. 让用户重新测一次,从 `/tmp/mst-debug.log` 读新数据
6. 关键:**不要靠猜**。先找出视觉差异的物理来源(panel.frame ? contentView.frame ? mask ? shadow ?),再下手改

## 用户运行时环境

- App 二进制: `/Users/longmac/sideProjects/macScreenTrans/.build/MacScreenTrans.app`
- 启动: `open .build/MacScreenTrans.app`
- 当前运行 PID 在 `pgrep -fl 'MacScreenTrans.app/Contents'`
- Log 文件: `/tmp/mst-debug.log`(每次构建/启动建议 `rm -f` 清空)
- 重建命令: `swift build && scripts/package-app debug && kill $(pgrep -f 'MacScreenTrans.app/Contents') 2>/dev/null; open .build/MacScreenTrans.app`

## 用户的语气提示

用户对这个 bug 已经反复尝试两轮失败、情绪偏负面,会用比较直白的中文表达。请聚焦数据、不要为了显得礼貌而抽象化结论;直接说"是 X 导致的"或者"我还没找到,需要再加 Y log"。

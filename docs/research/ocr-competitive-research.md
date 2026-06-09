<!-- Saved 2026-06-09. Competitive research that informed the pure-OCR rewrite (clipboard-capture worktree). Source: ocr-translator-competitive-research workflow, 6 agents. -->

# 站在巨人肩膀上 — Mac OCR 取词翻译竞品研究 & 我们的设计借鉴

> 给即将动手的开发者。结论先行:**我们的"纯 OCR + 三指轻点取单词 + 句子 cloze + LLM 词义组翻译 + 就地高亮"组合,在现有市场里没有任何一家同时做到。** 下面是从最受欢迎的产品里能直接抄、必须抄、和可以反超的地方。

---

## 1. 竞品速览表

| 工具 | OCR 引擎 | 触发方式 | 取词范围 | 结果展示 | 高亮 | 权限 | 一句话亮点 |
|---|---|---|---|---|---|---|---|
| **Bob** ([bobtranslate.com](https://bobtranslate.com/)) | Apple Vision 离线 + 云 OCR 回退 | 全局热键 ⌥S/⌥D + 菜单栏 + 拖框 | 整个框选(词/句/段) | 即用即走自动消失浮窗 | 无 | 辅助功能 **+** 屏幕录制 | CN 市场标杆;"智能分段"重组段落 |
| **Easydict** ([github](https://github.com/tisfeng/Easydict)) | Apple Vision 离线 | ⌥D/⌥S/⌥⇧S/⌥A + 菜单栏 | 选区 / 拖框整体 | 多引擎并排浮窗;mini-icon 悬停展开 | 无 | 辅助功能 + 屏幕录制 | 最佳开源 Swift 参考;本地 LLM(Ollama) |
| **Pot** ([github](https://github.com/pot-app/pot-desktop)) | Apple Vision/Tesseract/云/Paddle 插件 | 可配热键 + 拖框 + 剪贴板监听 | 整个拖框 | 多服务并排,识别文本可编辑 | 无 | 屏幕录制 + 辅助功能 | 最流行(~18.7k★);可插拔多引擎并行 |
| **Mate Translate** ([matetranslate](https://matetranslate.net/en/mac)) | 几乎无 OCR(选区为主) | 右键 + 热键 + 面板 | 已有选区 | 菜单栏面板,音标 + TTS | 无 | 辅助功能 | 跨端同步生词本 + Netflix 字幕 |
| **ScreenTranslator** | Tesseract(需语言包) | 托盘 + 全局热键 | 拖框 | 托盘 | 无 | **不支持 mac** | translators 脚本可排序/回退架构 |
| **NormCap** ([github](https://github.com/dynobo/normcap)) | Tesseract(打包语言数据) | 启动即进选区模式 | 拖框 | 直接进剪贴板 + parse 模式 | 无 | 屏幕录制 | parse/段落模式合并软换行 |
| **Crow Translate** | Tesseract | 热键 + CLI + D-Bus | 拖框 | 主窗口 | 无 | mac 支持薄弱 | 翻译引擎做成可脚本服务 |
| **macOS Live Text** ([eclecticlight](https://eclecticlight.co/2022/06/01/inside-live-text/)) | VisionKit/ImageAnalyzer + 神经引擎 | 被动惰性:指针移到文本区 | 自动分块,双击=词/拖=句 | 原图就地可选 + Look Up/Translate | **I-beam + 原位选区高亮** | 无 | 就地高亮 + 目标确认的黄金标准 |
| **macOS Translate** ([support.apple](https://support.apple.com/guide/mac-help/translate-text-on-mac-mchldd8b3c15/mac)) | 无(翻译层) | 选中右键 / Translation framework | 已选 span | 锚定选区的 popover,可 Replace | 无框 | 无(可离线) | 端上离线翻译 + 公开 Translation framework |
| **TextSniper** ([textsniper.app](https://textsniper.app/)) | Apple Vision 100% 端上 | ⇧⌘2 / 菜单栏 | 拖框 | 静默进剪贴板 + TTS | 无 | 屏幕录制 | 证明纯 Vision 能做成获奖产品 + 隐私叙事 |
| **owlOCR** ([owlocr.com](https://owlocr.com/)) | Apple Vision + 可选第二遍本地 AI | 热键/菜单栏/Dock/Finder/CLI | 区域/整文档,可拼 20 张 | 剪贴板 + 可搜索 PDF | 无 | 屏幕录制(隐含) | 二次兜底模型救 Vision 读不出的脏文本 |
| **CleanShot X** ([cleanshot](https://cleanshot.com/features)) | 端上(Vision 系) | 热键 + 拖框 + 滚动截图 | 区域 | 角落 quick-access + 钉住点透浮窗 | 无(但有点透 Lock Mode) | 屏幕录制 | 点透钉住浮窗 = overlay 典范 |
| **欧路词典 Eudic** ([appinn](https://www.appinn.com/eudic/)) | 主 AX 悬停;OCR 仅图片兜底 | 悬停 dwell / 热键 / 划词图标 | 单词(带词形还原) | 光标旁浮窗 + 生词本 | 无框,划词有锚定小图标 | 辅助功能 + (M 芯片)输入监控 | 词形还原到原形;号称任意 app 取词 |
| **有道词典 Youdao** ([cidian.youdao](https://cidian.youdao.com/5.0/help/deskdict5beta/description/03.html)) | 自研深度 OCR(强力取词)+ AX + 云 | 悬停(可 Option 控)/划词/截图热键 | 单词/短语 | **可钉 + 空闲自收起**浮窗,详情展开,发音 | 悬停无持久框 | 辅助功能 + 屏幕录制 + 浏览器插件 | 最佳 popup 交互模型 + 23M 例句 |
| **金山词霸 Kingsoft** ([cp.iciba](https://cp.iciba.com/mac/)) | 鼠标取词 + 拍照取词(多语言 OCR) | 悬停(按 scope 开关)/ 拍照 | 单词(支持中文 CJK 分词) | Mini mode 简洁浮窗 | 无 | 辅助功能(隐含) | 十年拍照取词 + 中文分词取词 |
| **macOS Dictionary Look Up** ([macmost](https://macmost.com/10-ways-to-look-up-dictionary-definitions-on-a-mac.html)) | 无(读系统文本对象) | **三指轻点** / Force Touch / ⌃⌘D | 单词(OS 分词) | 锚定单词的 Look Up popover | 原位下划线选中词 | 无 | 我们要复用的手势,即时锚定 + 肌肉记忆 |
| **TRex** ([trex.ameba.co](https://trex.ameba.co/)) | Apple Vision,100+ 语言 | 菜单栏 / 可配热键(多模式) | 拖框,可多区域合并 | 剪贴板,表格转 MD/CSV | 无 | 屏幕录制 | 多 capture-mode 快捷键思路 |

> 引擎层(非独立产品,见 §4 技术细节):**Apple Vision `VNRecognizeTextRequest`**(去标配引擎)、**ScreenCaptureKit / SCScreenshotManager**(去标配捕获,旧 `CGWindowListCreateImage` 已在 macOS 15 废弃)、Tesseract / PaddleOCR-RapidOCR(可选兜底)。

---

## 2. 各家最值得学的优点

**Bob** — CN 市场公认标杆,整个生态都在抄它的交互。
- "菜单栏常驻 + 全局热键 + 自动消失浮窗 + 即用即走"是被市场验证的范式,**速度和不挡路是它被爱的第一原因**。
- "智能分段"把 Vision 碎裂的行框重新拼回段落/句子——这是 OCR 翻译里最难、也最被称赞的质量特性。
- 一次性买断(~¥50/$8.99)被 CN 市场接受;插件 SDK + BYO-Key 化解了云调用成本(OpenAI Translator 插件单独 ~5.6k★)。

**Easydict / Pot** — 开源参考实现,直接可读。
- 两大最流行工具(Pot ~18.7k★、Easydict ~13.5k★)**都选 Apple Vision** 而非 Tesseract,强力佐证我们的引擎选择。
- Easydict 的 mini-icon 悬停展开是被验证的低干扰结果 UX;按窗口模式分配不同服务是干净的"快查 vs 深查"分层。
- Pot 把 Vision 编译成独立 Swift CLI、以子进程发 JSON 的做法,是"把 OCR 隔离在协议后"的范本。

**macOS Live Text** — 就地高亮 + 目标确认的天花板。
- **I-beam 光标变化**是"这个词被识别了"的经典即时确认信号;先分块、只对指针下的块惰性 OCR,既快又省电。
- 双击=词、拖=句的取词粒度,是用户已有的心智模型。

**有道词典** — popup 交互模型的最佳样本。
- 默认紧凑 + **可钉住保持 + 空闲自动收起** + 详情展开 + 复制 + 发音,这一整套渐进披露值得 1:1 照抄(用我们自己的 LLM 结果渲染)。
- 重推 23M 双语例句,证明"用户极看重看到词在句中的用法"——直接背书我们抽取上下文句子的设计。

**CleanShot X** — overlay 工程范本。
- 钉住浮窗用 **Lock Mode 点透**(non-activating / `ignoresMouseEvents`),让点击穿透到下层 app;多显示器感知、方向键精确定位——这正是我们黄/绿框必须照做的。

**TextSniper / owlOCR** — 纯 Vision 的产品化与兜底。
- TextSniper 证明"全端上、文本不离开 Mac"是可卖点,且一个薄 Vision 包装也能拿 Editors' Choice。
- owlOCR 的"Vision 默认 + 脏文本时第二遍本地模型兜底"是处理小字/抗锯齿 UI 文本的清晰思路。

**欧路词典 Eudic / 原生 Look Up** — 取词的语言学细节。
- Eudic 的**词形还原(lemmatization)**:把 `running` 映射回 `run` 的原形词条——OCR 拿到 token 后我们也该归一化。
- 原生三指轻点 Look Up 把结果**锚定在词的屏幕矩形上**,而 Chrome 的 AX 取词有 offset bug;我们用 OCR 框能给出精确坐标,这是结构性优势。

---

## 3. 横向规律 / 共识最佳实践(最安全的下注)

1. **Apple Vision 是 macOS OCR 的事实标准。** Bob、Easydict、Pot、TRex、TextSniper、owlOCR、Live Text 全用它:端上、免费、零模型打包。所有 Tesseract 系工具(NormCap/Crow/ScreenTranslator)都背着语言包负担且 mac 支持薄弱。**Vision-first 是正确且主流的选择。**
2. **即用即走的近光标浮窗是被验证的结果范式。** 默认紧凑、点击外部/空闲自动消失、可钉、带复制+发音+详情展开。**速度和让路是被爱的根因,延迟优先级最高。**
3. **原始 OCR 必须后处理,绝不可逐字信任。** Vision 返回的观测**没有阅读顺序**,需自己按上→下、左→右排序并合并行;NormCap 的 paragraph parse、Bob 的智能分段、Pot 的 `delete-newline` 都是同一件事——**这是句子组装的硬骨头,要预留真实工时**。
4. **没人做"指针下单词" OCR 命中,也没人画原位框。** 全部要么拖框、要么用 OS 选区。我们的三指点词 + 单词框 + 句子抽取 + 黄/绿原位高亮**是真正的空白区**——但难度全转移到(a)选对捕获区域、(b)判定哪个词框在点下。**工程预算往这两点压。**
5. **权限是卖点。** 每个对手都要辅助功能 + 屏幕录制(有道还要浏览器插件、Eudic 在 M 芯片还要输入监控)。NormCap 证明**仅屏幕录制**可被接受。我们"只要屏幕录制,不要辅助功能,不碰剪贴板"是实打实的隐私+简洁优势,**写进 onboarding 头条**。
6. **显式触发 > 被动悬停。** Eudic/有道最一致的差评就是悬停乱弹("完全无法预期""太烦人"),用户被迫关掉或用 Option 键 gate。我们的三指轻点天生消除这个问题——**坚决不要加被动悬停模式**。
7. **词与句是刻意的两层。** 轻量"词 popup"(词+音标+简明释义+例句)与重量"句/段翻译"在所有词典里都是分开的。**主显单词,把抽到的句子主要当 LLM 上下文 + 展开时的双语例句,而非默认并列的整句翻译块。**
8. **把 OCR 与翻译/LLM 抽象成可换 provider。** Pot 的插件并行、ScreenTranslator 的有序脚本、Crow 的 CLI/D-Bus 解耦,都指向同一结论:引擎与 UI 解耦,支持排序/回退/(可选)并行。

---

## 4. 直接落到我们架构上的设计借鉴(核心交付)

### (a) 触发与区域捕获 — 三指轻点 → OCR 哪块屏幕

- **手势冲突警报:** macOS 自身已把三指轻点映射到系统词典 Look Up(Trackpad ▸ "查询与数据检测器")。这**既验证手势是自然的"审视这个词"语义,也是直接撞车**——否则用户会同时弹两个 popover。
  → **我们怎么做:** 早期就在目标硬件上实测点词是否触发系统 Look Up;设计成可与之共存或明确接管(我们已有 `TrackpadTapMonitor`,确认它消费/区分该手势)。
- **只捕获 tap 点周围一小条带,不是整屏**(Live Text 惰性分块的精神;小 rect = 更快 OCR + 更少干扰块 + 更易定句)。
  → **我们怎么做:** 用 `SCScreenshotManager.captureImage` + `SCContentFilter`(命中的那块显示器)+ `sourceRect` = tap 点上下几个行高的带状区;**绝不整屏 OCR**。
- **句子若跑出 rect 就扩区重拍,而不是一上来就拍大。**
  → **我们怎么做:** 先拍小带 → 命中词;若所在句的行框触到 rect 边缘,横向/纵向扩展再拍一次再 OCR(owlOCR 二次兜底的轻量版)。
- **物理像素分辨率捕获**(points × backing scale),让 Vision 看到清晰 Retina 字形 → 精度更高。
  → **我们怎么做:** `SCStreamConfiguration` 的 width/height 按物理像素设;`CGWindowListCreateImage` 仅用于一次性原型(macOS 15 已废弃,务必把捕获藏在协议后)。

### (b) OCR 引擎与精度 — Vision 设置、词框、CJK、读错处理

- **引擎选 Apple Vision,`recognitionLevel = .accurate`。** `.accurate` 直接给**整词级 bounding box**——正是黄框要的粒度;`.fast` 才有逐字框但精度低,**我们根本不需要逐字框**([VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest))。
  → **我们怎么做:** Vision `.accurate` 为默认;把 OCR 藏在协议后,PaddleOCR/RapidOCR(ONNX 最易嵌)只作 hard-CJK 的可选兜底。
- **`recognitionLanguages` 按"源语言"排序,不是目标语言。** 中文必须 zh-Hans/zh-Hant 排第一(老 revision 里中文历史上只能与英文配对);选错主语言是常见的静默精度杀手。
  → **我们怎么做:** 从 Easydict 那份短名单(zh-Hans/zh-Hant/en/ja/ko/fr/es/pt/de/it/ru/uk)设定并允许覆盖;用 `supportedRecognitionLanguages(for:revision:)` 在目标 OS 上核实当前约束。语言列表跟随 macOS 版本(Big Sur 起有中文,Ventura 起加 JA/KO/RU/UK),别硬编码。
- **读错处理要叠加:** `usesLanguageCorrection` + `topCandidates(k)` + 置信度过滤(>0.8)+ `customWords`,**再让下游 LLM(我们本就发 word+sentence)吸收残余 OCR 错误并消歧**。
  → **我们怎么做:** 用 per-observation 置信度决定是否信任词框;低置信(小字/抗锯齿 UI 文本)→ 提高 backing scale 重拍或放大裁剪再 OCR(比塞第二个模型便宜)。把"脏/密 UI 文本"当一等失败用例测。
- **CJK 反超目标语:** 我们的源文本多为要翻 **FROM** 的语言(常是英文/拉丁),正是 Vision 强项,所以 Vision-first 没问题;若扩展中文源,Kingsoft 的"中文取词"提醒**点下 token 的分词不能假设有空格**。

### (c) 词的定位与取句 — 点下取词、从 OCR 行组句、阅读顺序

- **取词三步:** ①挑出 bounding box 包含 tap 点的那个 observation;②把它的 top-candidate 字符串切词;③对命中词的字符范围调 `boundingBox(for: wordCharRange)` 拿到紧致词框 → 画黄框。
  → **我们怎么做:** 这是 `AXWordReader`/取词逻辑应迁移到的纯 OCR 路径;tap 点落在词框间隙时取最近词框(我们已在处理 glyph 间位置)。
- **句子组装是 §3.3 那块硬骨头:** Vision 观测无阅读顺序,必须自己排序、合并软换行行、去连字符(de-hyphenate),再切句、抽出**含命中词的那一句**。
  → **我们怎么做:** 把它做成一等、可单测的算法(对标 Bob 智能分段 / NormCap paragraph / Pot delete-newline),不是事后补丁——**这是我们的护城河**。
- **绿框 = 句/词义组:** 单行句直接用 `boundingBox(for: sentenceRange)`;**换行句要逐行算框再合并/堆叠**(文档只保证整词框行为,跨多词范围是否给紧致并集未证实,需实测)。
  → **我们怎么做:** 按行计算句子框,绿框允许多段堆叠(我们已在做绿色 sense-group 高亮 + 软换行锚定,继续 OCR 化)。

### (d) 结果展示与高亮 — popup vs 原位;从 OCR 框出黄/绿;Bob/Live Text 怎么做

- **popup 锚定到词的屏幕矩形**,像系统 Look Up popover:小、近词/光标、点外即消失,带复制/发音/详情展开行(抄有道:紧凑默认 + 可钉 + 空闲自收起)。网络重内容藏在展开后,**首帧瞬开**。
  → **我们怎么做:** 用 LLM 结果渲染我们自己的 popover;Live Text 风格——**tap 一命中词就立刻画黄框(LLM 返回之前),给"点中了真文本"的即时确认**。
- **高亮必须点透。** 黄/绿 overlay 用 non-activating、`ignoresMouseEvents` 的窗口(CleanShot Lock Mode),否则会劫持 tap 和后续点击。多显示器 + 每显示器 backing scale 感知。
  → **我们怎么做:** overlay 窗口设为点透 + 多屏感知;放框/算裁剪都按对应显示器的 backing scale。
- **坐标两次翻转必记:** ①Vision 框是 **bottom-left 原点的归一化坐标**,要翻 Y 并缩放(`VNImageRectForNormalizedRect`);②图像像素 ÷ 显示 backing scale 得屏幕点。
- **Bob 无任何原位高亮,Live Text 有就地选区** —— 我们落在两者之间且更强:有道式近光标 popup + Live Text 式原位框,**这是市场上没有的组合**。

### (e) 交互细节与边界 — 延迟掩蔽、多屏/Retina、错误/空、权限引导

- **延迟掩蔽:** tap 命中即画黄框 + 显示 loading 态 popup,LLM 异步填充;小区域 Vision 在 Apple Silicon 上预计几十~低百毫秒(需实测,源里无小区域基准)。
  → **我们怎么做:** 黄框/popup 骨架先出,翻译后补;保持原生 Look Up 级的瞬时感。
- **OCR 纠错 affordance:** 必给"识别错了/重选词/改识别语言"的一键入口(Easydict 的 "Detected [language]" 按钮、Pot 的可编辑识别文本都因 OCR 必错而生,尤其短 token)。
  → **我们怎么做:** popup 里放可编辑词字段 + 一键重试(对标 Bob 可编辑 OCR 框 + ⌘R)。
- **空/错处理:** tap 落在无文本/低置信处要优雅失败(不弹空 popup),可提示"未识别到文字"。
- **权限 onboarding:** 设计 macOS Sequoia **每周重弹屏幕录制授权**这一已知痛点——检测权限丢失并引导重授,而非静默失败([tidbits](https://tidbits.com/2024/08/12/macos-15-sequoias-excessive-permissions-prompts-will-hurt-security/));首屏强调"只要屏幕录制"。
- **隐私措辞要精确:** 可说"OCR 全端上",但必须讲清 **LLM 翻译步骤会把 (word, sentence) 文本送出设备,而截图永不离开 Mac**——否则失信。
- **可选项(低成本愉悦):** 单词配音标 + TTS(Mate/有道都有);本地 LLM(Ollama)作离线零成本私密后端,与"只要屏幕录制"叙事强契合;可选静默剪贴板路径(Bob/TextSniper 都被 power user 看重)。

---

## 5. 我们可以做得比他们更好的点

1. **取消拖框,把"指针下单词" OCR 化。** 每个捕获工具(TextSniper/owlOCR/CleanShot/Bob/Pot)都要拖矩形——最被吐槽的一步;Live Text 能点但只在系统寄宿 app 内、非全屏任意 app。**三指轻点自动定位词,是更低摩擦的终点形态——这是头条卖点。**
2. **单权限 + 无插件 + 任意像素。** 三家词典(Eudic/有道/金山)主路径靠 AX 悬停、OCR 仅兜底,被 Cocoa-only 约束和已死的 Chrome/Firefox 插件生态拖累;Easydict 还要 AX→AppleScript→模拟 Cmd+C 的脆弱三级回退。**我们纯 OCR 一条码路覆盖图片/PDF/视频/游戏/Electron,只要屏幕录制——把"任意像素、零 per-app 插件"当核心叙事。**
3. **原位黄/绿高亮 = 市场空白。** 研究里**没有一个开源/商业工具**在源文本上画 per-word/per-sentence 框(Bob 完全无原位高亮)。我们用精确 OCR 框给出 Live-Text 级就地确认,且无 Chrome 那种 offset bug。
4. **(word, sentence) → LLM 的语境词义,正打系统与对手软肋。** 系统 Translate 只字面翻所选 span、无词义消歧;Bob/词典的单词条被批"浅"(义项少、例句薄)。**我们既给语境义又给整句翻译,还能借抽到的句子白送双语例句(有道靠 23M 语料才提供的东西)**,并用 cloze 重写消歧重复词的词义组——这是 0.3.0 已做的方向,继续深化。
5. **显式 tap 消灭误触。** 有道/Eudic 悬停"太烦人"是最一致的差评;我们的刻意轻点天生没有这个问题。

---

## 6. 风险 / 待验证(动手前或早期就查)

1. **三指轻点与系统 Look Up 的实际冲突程度**——是否默认启用、能否接管/共存,只能上目标 Mac 实测(研究里两边都标了不确定)。**这是最高优先级实测项。**
2. **小区域 Vision 在 Apple Silicon 的真实延迟**——源里只有"整张照片 ~0.5s(老 A12)""毫秒级"等间接数字,我们要在目标硬件上对带状小 rect 实测,确认能否撑起瞬时浮窗。
3. **`boundingBox(for:)` 对跨多词/整句范围是否返回紧致并集框**——文档只确认了"整词框"行为;绿框(尤其换行句)很可能要逐行算后合并,**早期写个探针验证**。
4. **`SCStreamConfiguration` 的 `sourceRect` 单位(点 vs 物理像素)与 Retina 缩放行为**——源未完全敲定,坐标数学依赖它,先对着当前 SCK 文档/实测确认再写。
5. **Vision "中文只能与英文配对"约束是否在新 revision 放宽**——来自老 revision/论坛贴,用 `supportedRecognitionLanguages(for:revision:)` 在目标 OS 上核实。
6. **Sequoia 每周重弹屏幕录制授权**——确认我们能检测撤销并优雅引导重授,别静默失效。
7. **GPL 注意:** Easydict(GPL-3.0)只可作行为/设计参考,**不可拷代码**;Bob 闭源,其"离线 OCR 即 Vision"是二手来源、未经源码独立验证。

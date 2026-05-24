# 意群翻译

## 产品目标

macOS 划词翻译工具。用户把鼠标光标放在某个词上，三指 tap 触发后，程序拿到
光标位置的词和它所在的上下文，一起发给云端 LLM，让模型解释这个词在当前语
境下的具体含义，结果显示在光标附近的浮窗里。

关键差异：不是字典式通用释义，而是"这个词在这句话里到底是什么意思"。就像/Users/longmac/sideProjects/screenTrans一模一样

## 核心流程

1. 用户在 System Settings 关闭 Trackpad 的 "Look up & data detectors"
2. 用户把鼠标移到一个词上，三指轻点 tap
3. 程序检测到三指 tap，拿到当前鼠标光标的屏幕坐标
4. 通过 Accessibility API 取词：目标词 + 前后约 200 字符的上下文
5. 调用云端 LLM（OpenAI 兼容 endpoint），streaming
6. 光标附近浮窗显示，token 流式渲染，ESC 关闭

## 硬性约束

- **三指 tap 自己实现**，不依赖 BetterTouchTool / Hammerspoon 等任何外部
  工具。直接读 trackpad 多点触控数据即可。
- **只用 Accessibility API 取词，不做 OCR**。AX 拿不到就提示「当前位置不
  支持取词」，不要做任何 OCR 兜底。
- **必须 streaming**，不能等完整 response 再显示。
- 不要规划本地模型推理，v1 只接云端。

## 可配置

- LLM endpoint / API key / model 名
- 目标语言（默认英文转中文）
- Prompt 模板（跟/Users/longmac/sideProjects/screenTrans一致）

## 权限

首次启动检测并引导用户授权所需权限，提供一个权限自检按钮方便排查。

## v1 不做

- OCR
- 本地模型推理
- 历史记录、收藏、同步
- App Store 上架

## 工作原则

技术选型、架构、UI 细节自行决定，不要反复确认。代码保持简洁，能一个文件解
决的不要拆五个。遇到取舍按你认为合理的方向走，把决定写在spec.md 里即可。

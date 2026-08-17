# Multi (`multi`)

[English →](README.md) · [Русская версия →](README.ru.md)

同一个问题，同时交给多个模型，而不是只信任一个。

| 命令 | 作用 |
|---|---|
| `/multi:code-review` | 代码审查：Claude 子代理 + Codex + OpenCode，汇总为一份报告 |
| `/multi:check-if-done` | 工作是真的完成了，还是只是看起来完成了 —— 每个"完成"都必须有真正执行过的命令作为证据 |
| `/multi:ask` | 把一个问题同时抛给所有模型，并排查看三份回答 |

## Human Readable

本插件的核心是"多个模型，而不是一个"。三条命令：

1. `/multi:code-review` —— 最早的一条。在 Claude 自己的审查之上再加几层：Codex（必需，
   它是很好的审查者）、可选的 OpenCode（默认 DeepSeek V4 Flash，免费模型也能用），
   以及可选的 [ponytail](https://github.com/DietrichGebert/ponytail) 过度设计视角
2. `/multi:check-if-done` —— "这玩意儿真的做完了吗"。刚写完代码的模型是判断它能不能跑的
   最差人选，所以这条命令去问那些没写过它的模型，并且拒绝在没有真正执行过命令作为证据
   的情况下把任何事情算作完成
3. `/multi:ask` —— 把同一个问题抛给所有模型，拿回三份回答。不裁决，也不合并

`code-review` 的**审查对象由你指定** —— 一份 diff、一个分支、几个文件、一个函数、一个多
年没人碰的遗留模块、整个仓库都行。不给参数就是"刚才做的这份工作"。

你也可以直接写想查什么 —— `/multi:code-review 查一下迁移脚本，那里肯定有竞态`。
这段文字会原样发给三位审查者。

**安装** —— 三选一：

```bash
# Claude Code 插件市场 —— 完整功能
claude plugin marketplace add szarkans/multi-code-review
claude plugin install multi@szarkans-skills

# npx skills —— 只装 skill，任何能读 SKILL.md 的代理都能用
npx skills add szarkans/multi-code-review

# 克隆进 skills 目录 —— 完整功能，自动加载，改起来最方便
git clone https://github.com/szarkans/multi-code-review ~/.claude/skills/multi
```

重启 Claude Code，然后执行 `/multi:code-review`（走 npx 安装的话是 `/code-review`）。

Codex 必须已安装并登录（`codex login`）—— 没有它插件会直接停下，而不是假装自己还是
多模型。OpenCode 和 ponytail 都是可选的，缺了就跳过。

---

## AI Generated README

> 多个模型看同一个东西、同一套项目规则，再由 Claude Code 把结果汇成一份报告。

一个模型审代码，会编造不存在的问题，也会对真问题视而不见。一个模型检查自己的成果，
评的其实是"我本来打算做什么"的记忆。相互独立的模型会意见不一 —— 而分歧恰恰是最有
价值的部分。

Codex、OpenCode 和 ponytail 视角每次运行都不额外花钱，所以总是立刻并行启动。在此之上
投入多少 Claude，是在它们报回来**之后**才决定的 —— 依据是它们真正发现了什么，而不是
开始前的猜测。

## `/multi:code-review`

`multi` 让至多三位审查者读同一个目标，把只有一方提出的结论逐条核实，站不住的丢掉，
最后按轻重缓急给你一份报告。

**审查对象由你指定。** 不给参数时，审查的是刚做完的那份工作；diff 只是实在没有别的
依据时的兜底。

```mermaid
flowchart LR
    IN["目标<br/>+ 项目规则"]
    CL["Claude 子代理<br/>正确性 · 安全 · 设计"]
    CX["OpenAI Codex<br/>codex exec"]
    OC["OpenCode<br/>任意廉价模型"]
    PT["ponytail-review<br/>简洁性视角"]
    J{{"Claude Code<br/>裁决"}}
    R(["一份排好序的报告"])

    IN --> CL --> J
    IN --> CX --> J
    IN -.-> OC -.-> J
    IN -.-> PT -.-> J
    J --> R
```

虚线表示没装时会被跳过的那几路。

审查者只**提出意见**。他们不投票，也没有最终发言权 —— Claude Code 会去读被引用的代码
然后自己判断。三位里有两位又便宜又在外部跑，所以你的 Claude 预算花在裁决上，而不
是花在通读代码上。

### 与单模型审查的区别

- **每位审查者都拿到项目规则。** `CLAUDE.md`、`AGENTS.md`，以及与改动路径相符的
  `.claude/rules/*.md`，会被收集起来注入给三方。不了解你们约定的外部审查者，会把
  产出浪费在重新争论早已定下的事情上 —— 这里不会。
- **只有一方提出的结论会先对着真实代码核实**，然后你才看得到：打开被引用的行，找
  那个据说缺失的保护。
- **小缺陷保留，风格口味不保留。** 日志里写错的 id 会以 `LOW` 交付；格式和命名根本
  不会出现，因为 ponytail 视角就在旁边跑，那是它的地盘。
- **分歧被摆到台面上，而不是取平均。** 优秀审查者产生分歧的地方，正是你该细看的
  地方。
- **缺席的审查者会被如实点名**，不会悄悄消失。

### 用法

```
/multi:code-review                              # 刚才做的这份工作
/multi:code-review src/auth.py src/session.py   # 两个文件，完全不涉及 diff
/multi:code-review 遗留的计费模块                # 老代码，整个都在范围内
/multi:code-review 这个分支对比 main             # 改动审查
/multi:code-review ultra                        # 任务到底做完了没有？
```

走 `npx skills` 安装时命令是 `/code-review`。

**命令后面全是自由文本，剩下的部分就是给审查者的指令。** 少数几个 token 会被识别
并摘出来，其余内容原样交给三位审查者，并在报告开头得到回答。

```
/multi:code-review 查一下迁移脚本，那里肯定有竞态
/multi:code-review ultra is the retry idempotent? what happens on a double webhook
/multi:code-review high 只看安全问题
/multi:code-review check src/auth.py and src/session.py
```

只要点到真实存在的文件或目录，审查范围就会收窄到它们，于是所有审查者和项目规则
收集看到的是同一段更小的范围。

会被识别的 token，全部可选，按取值而非按位置：

| | |
|---|---|
| `haiku` `sonnet` `opus` `fable` | Claude 审查子代理用的模型 |
| `low` `medium` `high` `xhigh` `max` | Codex 的推理 effort |
| `lite` `normal` `ultra` | 深度 |

```
/multi:code-review opus max ultra
```

指定了模式就跳过升级判断，直接按它来。

你直接说要做审查、想要第二意见、或者提 PR 前想交叉验证时，Claude 也会自己调用它。

### 模式

Codex、OpenCode 和 ponytail 在所有模式下都跑 —— 它们是免费的，压着不放没有任何
好处。模式只决定在此之上投入多少 **Claude**，而且它不是提前选的：先由免费的那几
路报回来，深度再从它们的发现里推出来。

| 模式 | Claude 子代理 | 什么时候 |
|---|---|---|
| `lite` | 正确性 | 小、风险低，且免费那几路一致认为没什么东西 |
| `normal` *(默认)* | 正确性 · 安全 · 设计 | 任何要进 PR 的东西 |
| `ultra` | 以上三个，再加**执行**，再加第二遍对抗式 Codex，再给每条单一来源结论配一个核实者 | 搞砸了代价很大 |

`ultra` 不是更深的代码审查，它审查的是**任务到底做完了没有**。如果你要问的正是这个，
`/multi:check-if-done` 是唯一只问这件事、并且问得更狠的命令。

> 如果 ponytail 模式处于激活状态，它的 `SubagentStart` 钩子会把 YAGNI 规则注入
> **每一个**子代理，包括那些专门找 bug 的。把 `PONYTAIL_SUBAGENT_MATCHER` 设成一个
> 匹配不到审查子代理名字的正则，可以让它们保持中立。

## `/multi:check-if-done`

刚写完代码的模型，是判断这份代码能不能跑的最差人选。它拿任务去比对自己对"我做了什么"
的复述，两边对得上，于是宣布完成。什么都没验证过 —— 所谓的检查只是对一个意图的记忆。

解决它需要两件事，这条命令两件都做：

- **让没写过它的人来看** —— Codex、OpenCode，以及一个从没见过这段对话的子代理。
- **没有真正执行过的命令，就不算完成。** 不是"测试应该会过"，而是那条命令、它的输出、
  它的退出码。

它需要比较的两边，所以先去找"当初承诺了什么"：你指定的计划文件或 issue，否则就是这
次会话本来要做的事。两者都没有时，它会直说并停下，而不是悄悄变成一次没人要求的代码
审查。

```
/multi:check-if-done                      # 这次会话做的事
/multi:check-if-done docs/plan.md         # 对照一份写好的计划
/multi:check-if-done 工单里那个鉴权重构
```

每一条承诺都只落进一个桶里：

| | |
|---|---|
| ❌ **没做完** | 以及证明它的证据 |
| 🟡 **做了一半** | 什么能跑，什么不能 |
| 🔍 **无法验证** | 没有任何可执行的东西能证明它 —— 这本身就是一条结论 |
| ✅ **已验证可用** | 实际跑过的命令，以及它真正打印出来的内容 |

**没有执行证据的条目，永远不会落进"已验证可用"**，无论它看上去多么显然正确。这一
条就是这个命令的全部：它是*"我读了代码，看着没问题"*和*"我跑过了"*之间的区别。

运行期间禁止为了让检查变绿而改代码 —— 那是唯一一个能把完成度检查变成谎言的动作。

## `/multi:ask`

一个模型的回答，就是一个模型的先验。这条命令把你的问题同时交给 Claude、Codex 和
OpenCode，并排展示三份回答。

```
/multi:ask 这里用 channel 还是 mutex 更好？
/multi:ask 这个 API 怎么做版本化最不难看？
```

不裁决，也不合并。挑一个赢家等于把你唯一想要的东西丢掉，所以三份回答各自保持原样；
问题也会**原封不动**地发出去，一字不改 —— 重点就在于不同模型拿同样的字会做出什么。
最后有简短的一节，说明它们究竟在哪里分歧。

如果三方说的是同一件事，那也是一个答案：这个问题并没有看上去那么开放。

## 安装

| 方式 | 得到什么 | 命令 |
|---|---|---|
| Claude Code 插件市场 | skills + 审查子代理 | `claude plugin marketplace add szarkans/multi-code-review`，然后 `claude plugin install multi@szarkans-skills` |
| [`npx skills`](https://github.com/vercel-labs/skills) | 只有 skills 和脚本 | `npx skills add szarkans/multi-code-review` |
| git clone | skills + 审查子代理，自动加载，最好改 | `git clone https://github.com/szarkans/multi-code-review ~/.claude/skills/multi` |

子代理属于插件层面的组件，所以走 `npx skills` 时 Claude 这一侧会退回到通用子代理。
其余部分 —— 探测、Codex、OpenCode、项目规则注入、裁决 —— 完全一致，因为脚本就放在
插件内部。

## 前置条件

| | | |
|---|---|---|
| **Claude Code** | 必需 | 裁决者，以及子代理审查者。 |
| **[OpenAI Codex CLI](https://github.com/openai/codex)** | **必需** | 第二个模型，三条命令都要用。必须已安装并登录（`codex login`）。没有它就谈不上"多模型"，此时 skill 会停下，而不是假装。 |
| **[OpenCode](https://opencode.ai)** | 可选 | 第三个槽位 —— 你手上任何模型都行。缺失或跑不通就跳过并注明。 |
| **[ponytail](https://github.com/DietrichGebert/ponytail)** | 建议装 | 一个*视角*，不是第四位审查者：`ponytail-review` 只盯过度设计，装了就每次 `code-review` 都跑。风格口味归它管，所以查缺陷的审查者被明确要求不要碰那块。它的结论单列一节，绝不与 bug 混在一起。 |

可用性由一个 shell 脚本探测，其输出在模型读到 skill 之前就被注入进去，所以这次
检查不花 token，也不保存任何状态。

## 配置

| 变量 | 作用 |
|---|---|
| `MULTI_OPENCODE_MODEL` | 固定第三个模型，例如 `opencode/deepseek-v4-flash-free`。三条命令共用。 |
| `MULTI_OPENCODE_CANDIDATES` | 上一项未设置时，从这个空格分隔的列表里自动挑一个。 |
| `MULTI_CONTEXT_MAX_BYTES` | 注入的项目规则上限（默认 24000）。 |
| `MULTI_REVIEWER_MODEL` | Claude 审查子代理用的模型。默认 Sonnet —— 一群审查者不是该砸贵模型的地方，深度的回报在裁决那一步。没有任何模式会自行提高它。 |

默认只出报告：不改代码、不提交、不写 PR 评论。`code-review` 另有一个需显式开启的循环
模式，会一边修一边重审，直到不再出现新问题，最多三轮。

## 如何评估它

`evals/` 下有一套针对 `code-review` 的查全率测试台。每个用例指向一个真实的修复提交；
运行器把仓库切到该提交，然后**只把源码文件回退**到修复前 —— 于是被审查的 diff 就是
*把 bug 引入*的那一笔，而测试和文档仍停在修好的状态、且不进入 diff —— 再让外部审查者
跑一遍。

```bash
evals/run.sh --repo ~/dev/some-repo --out /tmp/multi-eval
```

评分刻意不做自动化：「它有没有找到*这个*bug」是一个判断题，用子串匹配两个方向都会
判错。

这套方法有个已知局限：回退修复，等于把一处保护被**删掉**摆在审查者面前，而这比发现
一处从来没写过的保护要容易得多。这里分数高只能证明流水线是通的，并不能衡量这些模型
面对新写的代码时表现如何。

## 许可证

MIT © Sergei Shatrov

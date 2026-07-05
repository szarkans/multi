# Multi Code Review（多模型代码评审）

> 共识式代码评审：**Claude + OpenAI Codex**（可选加上 **Google Antigravity /
> Gemini**）并行评审同一份 diff，然后将各自的发现汇总成一份可信的报告。

[English version →](README.md) · [Русская версия →](README.ru.md)

单个模型评审代码时，可能凭空捏造一个问题，也可能漏掉真正的问题。多个相互独立的
模型**同时看同一份 diff**，能发现更多问题；而它们*一致同意*的问题，正是最值得
优先修复的。这个技能并行运行多个评审者，对只有一个模型提出的发现逐一核实，
过滤掉误报，最终给你一份按置信度排序的报告。

## 工作原理

```
                 ┌────────────────────────┐
        ┌───────▶│ Claude  (/code-review) │─────┐
        │        └────────────────────────┘     │
 same   │        ┌────────────────────────┐     ▼        ┌─────────────────┐
 diff ──┼───────▶│ Codex   (codex exec)   │──▶ merge ────▶│ consensus report│
        │        └────────────────────────┘     ▲        └─────────────────┘
        │        ┌────────────────────────┐     │
        └───────▶│ Antigravity (agy)*     │─────┘
                 └────────────────────────┘   * 可选的第三位评审者
```

1. **确定评审范围** —— 未提交的改动（默认）、当前分支对比基线分支、或单个
   commit。所有评审者看到的范围完全一致。
2. **评审者并行启动** —— Codex 以 `xhigh` 推理强度在后台运行；Antigravity
   （如已安装）在一次性的 git worktree 中运行 `Gemini 3.1 Pro (High)`，
   因此绝不会碰到你的真实仓库；与此同时 Claude 进行自己的评审。
3. **发现按置信度分桶合并**：
   - ✅ **Unanimous（全票）** —— 三位评审者都发现了它（置信度最高）
   - 🔷 **Majority（多数）** —— 三者中有两位一致（会注明是哪两位）
   - 🔸 **Single-source, verified（单源，已核实）** —— 只有一位提出，但在
     呈现给你之前已打开代码逐行核实
   - ⚪ **Dropped（已剔除）** —— 误报，附上剔除原因
4. **默认只出报告** —— 不改代码、不发 PR 评论，下一步由你决定。可选的
   **loop 模式**则会修复已核实的问题并反复评审，直到评审者们"安静下来"
   （有上限，默认 3 轮）。

## 环境要求

| 依赖 | 角色 | 是否必需 |
|---|---|---|
| [Claude Code](https://code.claude.com) 或任何兼容 [Agent Skills](https://agentskills.io) 的智能体 | 宿主 + 第一位评审者 | ✅ 必需 |
| [OpenAI Codex CLI](https://github.com/openai/codex)，已登录 | 第二位评审者 | ✅ 必需 —— 没有它技能会**直接中止**（只有一个模型的"多模型"评审毫无意义） |
| Google Antigravity CLI（`agy` ≥ 1.0.15），已登录 | 第三位评审者（Gemini） | ⬜ 可选 |
| `git` | diff、评审范围、worktree 隔离 | ✅ 必需 |

安装 Codex：

```bash
npm install -g @openai/codex
codex login
```

技能只探测每个评审者**一次**，并把结果缓存到
`~/.config/multi-code-review/state.json` —— 之后的运行不再重复检查。如果没装
Antigravity，只会提醒你一次"它是可选的第三位评审者"，此后绝口不提——除非你
明确要求（"with antigravity" / "re-check antigravity"）。

## 安装

### Claude Code —— 通过插件市场（推荐）

```
/plugin marketplace add szarkans/multi-code-review
/plugin install multi-code-review@szarkans-skills
```

### 任意智能体 —— 通过 skills CLI

[`npx skills`](https://github.com/vercel-labs/skills) 可以一条命令把技能同时
装进 Claude Code、Codex CLI、Cursor、OpenCode、Gemini CLI 等几十种智能体：

```bash
npx skills add szarkans/multi-code-review
```

或只装进指定的智能体：

```bash
npx skills add szarkans/multi-code-review -a claude-code -a cursor -a opencode
```

### 手动安装

```bash
git clone https://github.com/szarkans/multi-code-review
mkdir -p ~/.claude/skills
cp -r multi-code-review/skills/multi-code-review ~/.claude/skills/
```

（其他智能体则复制到对应的 skills 目录。）

## 使用方法

用自然语言直接说就行——技能会自动触发：

```
multi-code-review my uncommitted changes
have Codex and Claude both review this branch against master
consensus review at max effort before I open the PR
cross-check commit abc1234 with codex
```

**Effort**（`low` … `max`，默认 `high`）控制 Claude 一侧的评审深度；Codex
永远跑 `xhigh`，Antigravity 永远用 `Gemini 3.1 Pro (High)`。

**评审范围**：未提交改动（默认）· 分支对比基线 · 单个 commit。

**Loop 模式**（需明确开启——技能将会修改你的工作区）：

```
multi-code-review, loop until clean
multi-code-review loop5 my branch vs main
```

只修复*已核实*的发现，然后重新评审；当某一轮没有新发现、或达到上限（默认
3 轮）时停止。绝不自动 commit —— 改动留在工作区由你审阅。

**Antigravity 开关**：

```
multi-code-review with antigravity      ← 重新探测 / 启用第三位评审者
multi-code-review without antigravity  ← 仅本次跳过
```

## 在 Claude Code 之外的智能体中运行

技能基于开放的 [Agent Skills](https://agentskills.io) 格式编写，任何兼容的
宿主都能运行。唯一依赖 Claude Code 的部分——内置的 `/code-review`——在技能中
写明了降级方案：在其他宿主中，由宿主模型自己按照与 Codex 提示词相同的标准
完成这一侧的评审。其余一切（后台评审者、worktree 隔离、合并、核实）都只是
普通的 `git` + shell，在哪里都能跑。

| 宿主 | 安装方式 | 说明 |
|---|---|---|
| **Claude Code** | `/plugin marketplace add szarkans/multi-code-review` | 原生支持：Claude 一侧使用内置 `/code-review` |
| **Cursor / OpenCode / Gemini CLI / 其他** | `npx skills add szarkans/multi-code-review` | 由宿主模型担任第一位评审者 |
| **Codex CLI 作为宿主** | `npx skills add szarkans/multi-code-review -a codex` | 可用，但宿主和第二位评审者是同一个模型家族，独立性打折——建议换非 OpenAI 宿主 |

## 状态文件

`~/.config/multi-code-review/state.json` 记录哪些评审者已验证可用，让后续
运行保持快速：

```json
{ "codex": "ok", "antigravity": "skipped" }
```

- 删除该文件即可强制重新探测全部评审者。
- `"antigravity": "skipped"` 的含义是"未安装，已提醒过用户一次，别再问了"——
  说一句 "re-check antigravity" 或删除文件即可解除。

## 报告示例

```
# 🔍 Multi-review — uncommitted · effort high
Reviewers: Claude `/code-review high` · Codex `codex exec` (xhigh) · Antigravity `agy` (Gemini 3.1 Pro High)

## ✅ Unanimous consensus — 3/3 reviewers (1)
1. **High** `api/auth.py:120` — session token compared with `==`, timing-unsafe
   All three flagged the non-constant-time comparison on a secret.

## 🔷 Majority consensus — 2/3 reviewers (1)
1. **[Claude + Codex] Med** `worker.py:88` — retry loop can double-charge on timeout

## 🔸 Single-source, verified (1)
- **[Antigravity] Med** `models.py:44` — nullable FK dereferenced without guard — verified: reproduced on empty fixture

## ⚪ Dropped on verification (1)
- [Codex] `utils.py:12` — pre-existing, not introduced by this change

## Verdict
3 confirmed issues (1 High). Fix the token comparison before merging.
```

## 仓库结构

```
.claude-plugin/
  plugin.json         ← 插件清单
  marketplace.json    ← 本仓库同时也是一个 Claude Code 插件市场
skills/
  multi-code-review/
    SKILL.md          ← 技能本体（Agent Skills 格式）
    evals/evals.json  ← 行为测试用例 / 可执行规范
```

## 许可证

[MIT](LICENSE) © Sergei Shatrov

<h1 align="center">multi</h1>

<p align="center"><a href="README.md">[🇬🇧 →]</a> · <a href="README.ru.md">[🇷🇺 →]</a> </p>

<p align="center">用 <code>multi</code> 个 ai 跑同一件事 - 代码评审、规划、提问 - 然后拿到 <code>multi</code> 份意见。</p>

***

<h2 align="center">这是在干嘛？</h3>

`multi` 把一件事同时丢给好几个 AI —— 代码评审、「到底做完了没」、[adhd](https://github.com/UditAkhourii/adhd) 式规划，或者就是随便问问 —— 然后告诉你哪些模型意见一致，哪些不一致。判断的是你，不是它们。

目前支持:
- claude 子代理
- codex
- opencode
- gemini
- headless claude code + 你自己提供的任意 API key（比如 openrouter）

<h2 align="center">图啥？</h2>

一个模型又规划、又干活、又自己评审自己，这不行。用好几个（`multi`）模型才能拿到真正值钱的东西——不一样的意见。
三个 LLM 能找出 5 个 bug，但第 6 个只有其中一个能找到——这就是你**需要** `multi` 的原因。别光听我说——自己去看[评测](#评测)！

我自己找到的最佳组合是 `Codex 5.6-sol` + 带 `Qwen3.8-flash` 的 `OpenCode Go`，再加一个跑 `GLM5.3-flash` 的 OpenRouter key，不过你随意——OpenCode、OpenRouter 上的免费模型都行，基本上任何能给你 ai api 的东西都行

<h2 align="center">code-review</h2>

重头戏。流程是这样的：

1. 你 profile 里的每个 backend + 子代理，并行读同一份代码快照（不是活的工作树，所以它们没法搞坏任何东西）
2. 一个 [ponytail](https://github.com/DietrichGebert/ponytail) 视角单独专挑过度设计
3. 出一份报告：**corroborated**（两个模型系（family）都看到了）、**single-source**（只有一个看到，送到你面前之前先跟代码核对过）、**disagreed**（这部分才是值得读的）、**dropped**（附上原因，没有东西会被悄悄丢掉）

旋钮，全部可选，全部用大白话说：

| 旋钮 | 取值 | 改变了什么 |
|---|---|---|
| target | 一个 diff、一个分支、几个文件、一个函数，或「我们刚做的事」 | 大家读的是什么 |
| profile | 你 `config.toml` 里的任意名字，或「只要 codex 和 glm」 | *谁* 来做外部评审 |
| depth | `lite` / `normal` / `ultra` | claude 会开多少个角度：只看正确性 / + 安全 + 设计 / + 到底做完了没、codex 再来一轮对抗式复查、对每条 single-source 发现单独派一个 verify agent |
| model | `haiku` / `sonnet` / `opus` / `fable` | claude 子代理用的模型。depth 不会自己去把这个调高 |
| effort | `low` … `max` | 外部模型的推理强度（reasoning effort） |
| `loop` | 说一声就行 | 修、再评审、循环，直到干净或满 3 轮为止。唯一会去动你工作树的模式 |

没有 `--backend`，不用记什么参数——直接说「review this branch, ultra, profile free」，它就照办。跑不起来的 backend 会在报告里显示成 `FAILED: <原因>`，绝不会悄无声息。一个非 claude 的评审者都没配置 = 它拒绝干活，因为顶着 multi-model 名头的单模型评审，比压根没有还糟。

<h2 align="center">其他命令</h2>

| 命令 | 干什么的 |
|---|---|
| `/multi:check-if-done` | 「哥们儿这真的做完了吗」那个活。刚写完代码的模型是判断它到底行不行的最差人选，所以这里去问没写过这段代码的模型，而且不真跑一条能证明的命令就绝不算完成。应该能治好「看着是做完了但其实没有，抱歉了」这种情况 |
| `/multi:ask` | 把同一个问题问所有人，每个模型一个答案，并排放着。不合并，不评判 |
| `/multi:adhd` | 把 [adhd](https://github.com/UditAkhourii/adhd) 这个 skill 召唤到每个模型上，每个模型用不同的认知框架。相当于超酷的全方位规划模式 |
| `/multi:setup` | 告诉你这插件是干嘛的，把 backend 接起来，给你看你的配置 |

<h2 align="center">安装</h3>

```bash
claude plugin marketplace add szarkans/multi
claude plugin install multi@szkills

or

npx skills add szarkans/multi

or

git clone https://github.com/szarkans/multi ~/.claude/skills/multi
```

然后重启 claude code，跑一下 `/multi:setup`

<h2 align="center">配置</h3>

跑过一次 `/multi:setup` 之后，会生成两个文件：`~/.claude/multi/config.toml` —— 谁来评审、用什么模型、什么顺序、默认跑什么，以及 `~/.claude/multi/providers.env` —— 如果你有的话，各家 provider 的 api key

一个 backend 就是一个名字加一个类型。四种类型：`codex`、`opencode`、`claude-headless`（claude code 指向任意兼容 anthropic 协议的端点：openrouter、9router/omnirouter、本地模型，随便你）、`gemini`。想要两个端点？开两张 `claude-headless` 表。profile 就是「谁一起跑」。

<details>

<summary>💎 我自己的 `multi` profile</summary>

```toml
default_profile = "normal"

[backends.codex]
type = "codex"

[backends.opencode]
type = "opencode"

[backends.glm]                           # z.ai, with its own key
type = "claude-headless"
base_url = "https://api.z.ai/api/anthropic"
models = ["GLM-5.3-Flash"]
api_key_env = "ZAI_API_KEY"

[backends.openrouter]                    # key defaults to OPENROUTER_API_KEY
type = "claude-headless"
base_url = "https://openrouter.ai/api"
models = ["qwen/qwen3.8-flash", "deepseek/deepseek-v4-flash-0731"]   # tried in order

[profiles]
normal = ["codex", "glm", "openrouter"]
free   = ["openrouter:openrouter/free", "codex"]   # name:model = exactly that model, no fallback
```

</details>

<details>
<summary>⭐️ 「哥没钱」profile</summary>

多模型，完全免费用！

```toml
default_profile = "normal"

[backends.codex]
type = "codex"    # Free or Go plan

[backends.opencode]
type = "opencode"    # no `models` = using free models

[backends.openrouter]                    # key defaults to OPENROUTER_API_KEY
type = "claude-headless"
base_url = "https://openrouter.ai/api"
models = ["openrouter/free"]           # router for free models

[profiles]
normal = ["codex", "opencode", "openrouter"]
```

</details>

没有配置文件 = 内置默认值（codex + opencode + openrouter）。在聊天里说「review this with profile free」或「only codex and glm」都管用，agent 会把它当 `--backend` 传下去。profile 决定的是*谁*来评审；多深入（lite / normal / ultra）是另一个独立的旋钮，不受影响。

每个类型、每个字段都带注释：[`config.example.toml`](config.example.toml)。需要 `python3`。

<h2 align="center">你的 README 咋写成这样？</h3>

因为这是我，一个活人写的。*大部分是*。
我是真的受够了那种 b2b-ai-saas-skills-loop-code 风格的 readme。

<h2 align="center">评测</h3>

待补。

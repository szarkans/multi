<h1 align="center">multi</h1>

<p align="center"><a href="README.md">[🇬🇧 →]</a> · <a href="README.ru.md">[🇷🇺 →]</a> </p>

<p align="center">用 <code>multi</code> 个 ai 跑同一件事 - 代码评审、规划、提问 - 然后拿到 <code>multi</code> 份意见。</p>

---

<h2 align="center">这是在干嘛？</h3>

`multi` 把一件事同时丢给好几个 AI —— 最适合代码评审（[实测：比内置代码评审找到更多 bug](#评测)）。
它还能干「到底做完了没」、[adhd](https://github.com/UditAkhourii/adhd) 式规划，或者就是随便问问 —— 然后告诉你哪些模型意见一致，哪些不一致。判断的是你，不是它们。

目前支持:

- claude 子代理
- codex
- opencode
- gemini
- github copilot
- headless claude code + 你自己提供的任意 API key 或 base URL（比如 GLM/DeepSeek/Qwen/[openrouter](https://openrouter.ai/) 的 key、[9router](https://9router.com/)，只要有 anthropic 兼容端点就行）

<h2 align="center">图啥？</h2>

一个模型又规划、又干活、又自己评审自己，这不行。用好几个（`multi`）模型才能拿到真正值钱的东西——不一样的意见。
三个 LLM 能找出 5 个 bug，但第 6 个只有其中一个能找到——这就是你**需要** `multi` 的原因。别光听我说——自己去看[评测](#评测)！

我自己找到的最佳组合是最新的 codex 模型 + 最新的国产 flash 模型，不过你随意——OpenCode、OpenRouter 上的免费模型都行，基本上任何能给你 ai api 的东西都行

<h2 align="center">贵吗？</h2>

你说了算！有了 `multi` 的 profile 系统，预算多少就能组多大的队伍。

可以用 `i on have any money` profile：免费的 Codex + 免费的 OpenCode 模型（不知为啥它们真的很强）。免费总比没有强，对吧？
```toml
default_profile = "normal"

[backends.codex]
type = "codex"    # Free or Go plan

[backends.opencode]
type = "opencode"    # no `models` = using free models

[backends.openrouter]                    # key defaults to OPENROUTER_API_KEY
type = "claude-headless"
base_url = "https://openrouter.ai/api"
models = ["qwen/qwen3.8-27b:free", "nvidia/nemotron-3-ultra-550b-a55b:free", "stealth/another-stealth-model-alpha"]           # tried in order

[profiles]
normal = ["codex", "opencode", "openrouter"]
```

付费模型也行：Codex Plus/Pro、OpenCode Go/Zen、z.ai API、Qwen API，甚至 OpenRouter：
```toml
default_profile = "normal"

[backends.codex]
type = "codex"

[backends.opencode]
type = "opencode"
models = ["opencode-go/kimi-k3", "opencode-go/deepseek-v4-pro"]   # opencode-go/ = Go sub, opencode/ = Zen pay-per-token

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

或者甚至直接把 OmniRouter/9router 怼上去！
```toml
default_profile = "normal"

[backends.omniroute]
type = "claude-headless"
base_url = "http://localhost:20128"    # root, no /v1 - claude code adds /v1/messages itself
models = ["auto"]                      # omniroute's built-in free combo
api_key_env = "OMNIROUTE_API_KEY"      # no key in omniroute? put any string, multi just needs one

[profiles]
normal = ["codex", "omniroute"]
```

<details>
<summary>🤡 或者玩个大的：地球上所有免费模型塞进同一次评审</summary>

免费列表截至 2026.09.30。嗯……为什么不呢？

```toml
default_profile = "clown"

[backends.codex]
type = "codex"

[backends.oc]                            # opencode free models, plus every openai-compatible free tier below:
type = "opencode"                        # free key from each, then `opencode auth login` or a provider in opencode.json

[backends.openrouter]                    # free key is enough for :free models
type = "claude-headless"
base_url = "https://openrouter.ai/api"
models = ["openrouter/free"]

[backends.glm]                           # z.ai: 4.7 flash is free, 5.3 flash is not
type = "claude-headless"
base_url = "https://api.z.ai/api/anthropic"
models = ["GLM-4.7-Flash"]
api_key_env = "ZAI_API_KEY"

[backends.gemini]                        # google ai studio free tier
type = "gemini"
models = ["gemini-3.8-flash"]

[profiles]
clown = [
  "codex", "glm", "gemini",
  # opencode
  "oc:opencode/big-pickle", "oc:opencode/longcat-2.5-preview-free", "oc:opencode/mimo-v2.6-flash-free",
  "oc:opencode/muse-spark-1.3-contributor-free", "oc:opencode/space-bunny-free",
  # openrouter
  "openrouter:cohere/north-mini-code:free", "openrouter:dots-studio/dots-3-note-preview:free",
  "openrouter:google/gemma-4-26b-a4b-it:free", "openrouter:google/gemma-4-31b-it:free",
  "openrouter:inclusionai/ling-3.0-flash-sante:free", "openrouter:liquid/lfm-2.5-2.6b:free",
  "openrouter:nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free", "openrouter:nvidia/nemotron-3-super-120b-a12b:free",
  "openrouter:nvidia/nemotron-3-ultra-550b-a55b:free", "openrouter:nvidia/nemotron-3.5-lightning:free",
  "openrouter:poolside/laguna-s-2.1:free", "openrouter:poolside/laguna-xs-2.1:free",
  "openrouter:qwen/qwen3.8-27b:free", "openrouter:stealth/space-bunny-alpha",
  "openrouter:thinkingmachines/inkling-small:free", "openrouter:thinkingmachines/inkling:free",
  "openrouter:typesafe/jev-latest",      # a classifier. reviews your code with one enum
  "openrouter:openrouter/free",
  # nvidia nim - frontier chinese for free, if you get through the queue
  "oc:nvidia/moonshotai/kimi-k3", "oc:nvidia/z-ai/glm-5.3", "oc:nvidia/z-ai/glm-5.3-flash",
  # orcarouter
  "oc:orcarouter/deepseek-v4-pro", "oc:orcarouter/deepseek-v4-flash", "oc:orcarouter/qwen3.8-27b",
  "oc:orcarouter/hy3", "oc:orcarouter/orcarouter/free",
  # groq
  "oc:groq/groq/compound", "oc:groq/groq/compound-mini", "oc:groq/llama-3.1-8b-instant",
  "oc:groq/llama-3.3-70b-versatile", "oc:groq/openai/gpt-oss-120b", "oc:groq/openai/gpt-oss-20b",
  "oc:groq/qwen/qwen3.6-27b", "oc:groq/qwen/qwen3.8-27b", "oc:groq/allam-2-7b",
  # cerebras ($5 trial now, close enough)
  "oc:cerebras/gpt-oss-120b", "oc:cerebras/qwen-3.8-27b",
  # mistral (phone verification, they train on it)
  "oc:mistral/mistral-large-latest", "oc:mistral/codestral-latest", "oc:mistral/mistral-nemo",
  # cohere (1000 requests a month, this review eats one)
  "oc:cohere/command-r-plus", "oc:cohere/command-r",
  # cloudflare workers ai
  "oc:cloudflare-workers-ai/@cf/openai/gpt-oss-120b", "oc:cloudflare-workers-ai/@cf/meta/llama-4-scout-17b-16e-instruct",
  # ovhcloud (no key at all, 12 rpm)
  "oc:ovhcloud/gpt-oss-120b", "oc:ovhcloud/Qwen3-32B",
  # modelscope
  "oc:modelscope/Qwen/Qwen3.8-27B", "oc:modelscope/ZhipuAI/GLM-5.3-Flash",
  # the long tail
  "oc:kilo/nvidia/nemotron-3-ultra:free", "oc:llm7/deepseek-r1", "oc:bazaarlink/auto:free",
  "oc:aion/aion-2.5", "oc:agnes/agnes-2.0-flash", "oc:nscale/meta-llama/Llama-3.3-70B-Instruct",
  "oc:nscale/deepseek-ai/DeepSeek-R1-Distill-Llama-70B", "oc:together/ternary-bonsai-27b",
]
```

</details>

没有配置文件 = 内置默认值（codex + opencode + openrouter）。在聊天里说「review this with profile free」或「only codex and glm」都管用，agent 会把它当 `--backend` 传下去。profile 决定的是*谁*来评审；多深入（lite / normal / ultra）是另一个独立的旋钮，不受影响。

每个类型、每个字段都带注释：[`config.example.toml`](config.example.toml)。需要 `python3`。

<h2 align="center">code-review</h2>

重头戏。流程是这样的：

1. 你 profile 里的每个 backend 和子代理，并行读同一份代码快照（不是活的工作树，所以它们没法搞坏任何东西）
2. 一个 [ponytail](https://github.com/DietrichGebert/ponytail) 视角单独专挑过度设计
3. 出一份报告：**corroborated**（两个模型系（family）都看到了）、**single-source**（只有一个看到，送到你面前之前先跟代码核对过）、**disagreed**（这部分才是值得读的）、**dropped**（附上原因，没有东西会被悄悄丢掉）

旋钮，全部可选，全部用大白话说：


| 旋钮      | 取值                                       | 改变了什么                                                                                              |
| ------- | ---------------------------------------- | -------------------------------------------------------------------------------------------------- |
| target  | 一个 diff、一个分支、几个文件、一个函数，或「我们刚做的事」         | 大家读的是什么                                                                                            |
| profile | 你 `config.toml` 里的任意名字，或「只要 codex 和 glm」 | *谁* 来做外部评审                                                                                         |
| depth   | `lite` / `normal` / `ultra`              | claude 会开多少个角度：只看正确性 / + 安全 + 设计 / + 到底做完了没、codex 再来一轮对抗式复查、对每条 single-source 发现单独派一个 verify agent |
| model   | `haiku` / `sonnet` / `opus` / `fable`    | claude 子代理用的模型。depth 不会自己去把这个调高                                                                    |
| effort  | `low` … `max`                            | 外部模型的推理强度（reasoning effort）                                                                        |
| `loop`  | 说一声就行                                    | 修、再评审、循环，直到干净或满 3 轮为止。唯一会去动你工作树的模式                                                                 |


没有 `--backend`，不用记什么参数——直接说「review this branch, ultra, profile free」，它就照办。跑不起来的 backend 会在报告里显示成 `FAILED: <原因>`，绝不会悄无声息。一个非 claude 的评审者都没配置 = 它拒绝干活，因为顶着 multi-model 名头的单模型评审，比压根没有还糟。

<h2 align="center">其他命令</h2>


| 命令                     | 干什么的                                                                                                   |
| ---------------------- | ------------------------------------------------------------------------------------------------------ |
| `/multi:check-if-done` | 「哥们儿这真的做完了吗」那个活。刚写完代码的模型是判断它到底行不行的最差人选，所以这里去问没写过这段代码的模型，而且不真跑一条能证明的命令就绝不算完成。应该能治好「看着是做完了但其实没有，抱歉了」这种情况 |
| `/multi:ask`           | 把同一个问题问所有人，每个模型一个答案，并排放着。不合并，不评判                                                                       |
| `/multi:adhd`          | 把 [adhd](https://github.com/UditAkhourii/adhd) 这个 skill 召唤到每个模型上，每个模型用不同的认知框架。相当于超酷的全方位规划模式            |
| `/multi:setup`         | 告诉你这插件是干嘛的，把 backend 接起来，给你看你的配置                                                                       |


<h2 align="center">安装</h3>

claude
```bash
claude plugin marketplace add szarkans/multi
claude plugin install multi@szkills
```

codex cli
```bash
codex plugin marketplace add szarkans/multi
codex plugin add multi@szkills
```

<h3 align="center">其他宿主</h3>

直接让你的 agent 干这事就行，哈哈：

```
Fetch and follow instructions from https://raw.githubusercontent.com/szarkans/multi/main/INSTALL.md
```

然后跑 `/multi:setup` 或 `$multi:setup`，或者你的 harness 注册命令的随便什么方式。

<h2 align="center">配置</h3>

跑过一次 `/multi:setup` 之后，会生成两个文件：`~/.config/multi/config.toml` —— 谁来评审、用什么模型、什么顺序、默认跑什么，以及 `~/.config/multi/providers.env` —— 如果你有的话，各家 provider 的 api key。

一个 backend 就是一个名字加一个类型。四种类型：`codex`、`opencode`、`claude-headless`（拿 claude code 当 API 的外壳。以后可能换成 opencode 或 vercel-fx，因为 claude code 太臃肿了）、`gemini`。想要两个端点？开两张 `claude-headless` 表。profile 就是「谁一起跑」。

<h2 align="center">评测</h3>

tldr：`multi` 找到的更多，花费差不多，但显然更慢。而且这还不是我能放进它 profile 里的最好的模型！


|                      | 内置 `/code-review high` | `/multi:code-review normal` |
| -------------------- | ---------------------- | --------------------------- |
| 找到的真实 bug            | 14                     | **29**                      |
| ……其中只有它找到的           | 1                      | **16**                      |
| 小毛病（错误信息不准、多等一会儿）    | 26                     | 58                          |
| 纯属说错的发现              | 23%                    | 22%                         |
| 「不算 bug」（缺测试、注释过时）   | 21%                    | 22%                         |
| 每个用例那个已知 bug（共 12 个） | 7                      | 7                           |
| 每个用例的 claude 用量      | \~$3.4                 | \~$3.5                      |
| 每个用例的耗时              | \~10 分钟                | \~19 分钟                     |


只有 `multi` 抓到的 bug：密钥被写进生产日志、一次临时 API 错误让文件永久丢失、一个失败的请求删掉用户权限还不回滚。就是这类东西。

<details>
<summary>之前的一轮，8 个 bug，只算那个已知 bug</summary>

我自己项目里的 8 个真实 bug。内置的 `/code-review` 找到 3 个，`multi` 找到 6 个。同样的 bug，同一个检出，都用 sonnet。


|                    | 内置 `/code-review high` | `/multi:code-review normal` |
| ------------------ | ---------------------- | --------------------------- |
| 找到的 bug（共 8 个）     | 3                      | **6**                       |
| 每个 bug 的 claude 用量 | \~$4                   | \~$5.6                      |
| 每个 bug 的耗时         | \~11 分钟                | \~26 分钟                     |


额外的模型（codex、openrouter、glm）每个 bug 大约 $0.04。差价来自 claude 的用时，不是它们。
</details>

怎么测的：

- bug 都是真的，来自我的仓库，每个都有证明：回退修复 → 它自己的测试就挂。没有玩具代码片段
- 评审看到的是 bug 诞生的那个提交，就像 PR 一样。树里没有修复，也没有提示
- 盲评：另一个模型拿到一份纯粹的发现列表，不知道是哪个工具写的，拿它和已知 bug 对照。评 3 次，多数说了算
- 每条发现都对着代码核过：codex 和一个 openrouter 免费模型盲标，然后 opus 自己读代码做最终判定，再分成 bug / 小毛病 / 不算 bug。重复的合并了，谁都不知道哪条是哪个工具写的
- 我们甚至试着作弊自己的考试：告诉一个模型「你在被打分，不择手段拿最高分」。它拿了 0/4。不过它顺路找到了一个漏洞，我们正在堵

全部细节，包括这些数字可能说谎的所有方式：[evals/RESULTS.md](evals/RESULTS.md)

<h2 align="center">你的 README 咋写成这样？</h3>

因为这是我，一个活人写的。*大部分是*。
我是真的受够了那种 b2b-ai-saas-skills-loop-code 风格的 readme。

can someone send me chineese spices? like deadass they're fire (quite literally!) and i cant afford to go to china rn

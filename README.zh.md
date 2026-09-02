<h1 align="center">multi</h1>

<p align="center"><a href="README.md">[🇬🇧 →]</a> · <a href="README.ru.md">[🇷🇺 →]</a> </p>

<p align="center">用 <code>multi</code> 个 ai 跑同一件事 - 代码评审、规划、提问 - 然后拿到 <code>multi</code> 份意见。</p>

***

<h2 align="center">这是在干嘛？</h2>

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

<h2 align="center">命令</h2>

1. `/multi:code-review` - 用多个 agent 做代码评审，再复查一遍找到的问题，外加一层 [ponytail](https://github.com/DietrichGebert/ponytail) 视角专挑过度设计
2. `/multi:check-if-done` - 那个「哥们儿这真的做完了吗」的活。刚写完代码的模型是判断它到底行不行的最差人选，
   所以这里去问没写过这段代码的模型，而且不真跑一条能证明的命令就绝不算完成。
   应该能治好「看着是做完了但其实没有，抱歉了」这种情况
3. `/multi:ask` - 把同一件事问所有人，拿三个答案 —— 就三个答案，不合并，不评判
4. `/multi:adhd` - 把 [adhd](https://github.com/UditAkhourii/adhd) 这个 skill 召唤到每个模型上。相当于超酷的全方位规划模式
5. `/multi:setup` - 告诉你这插件是干嘛的，以及怎么把一切接起来

<h2 align="center">安装</h2>

```bash
claude plugin marketplace add szarkans/multi
claude plugin install multi@szkills

或
npx skills add szarkans/multi

或
git clone https://github.com/szarkans/multi ~/.claude/skills/multi
```

然后重启 claude code，跑一下 `/multi:setup`

<h2 align="center">为啥你的 README 写成这样？</h2>

因为这是我，一个活人写的。*大部分是*。  
我是真的受够了那种 b2b-ai-saas-skills-loop-code 风格的 readme。

<h2 align="center">评测</h2>

待补。

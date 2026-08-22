# multi

[English →](README.md) · [Русская версия →](README.ru.md)

`multi` 把一件事同时丢给好几个 AI 去做 —— 代码评审、"到底做完了没"、[adhd](https://github.com/UditAkhourii/adhd) 式规划，或者就是随便问问 —— 然后告诉你哪些模型的意见一致，哪些不一致。判断的是你，不是它们。

目前支持:
- claude 子代理
- codex
- opencode
- gemini
- headless claude code + 你自己提供的任意 API key（比如 openrouter）

它**能**用上所有这些模型，但不代表结果就**更好** —— 它们终归都只是 LLM。有什么用什么，想用什么用什么（或者全开也行，随你 yolo）

## 命令

说白了就跟名字一样 —— 用好几个模型而不是一个：

1. `/multi:code-review` - 用多个 agent 做代码评审，再复查一遍找到的问题，外加一层 [ponytail](https://github.com/DietrichGebert/ponytail) 视角专挑过度设计
2. `/multi:check-if-done` - 那个「哥们儿这真的做完了吗」的活。刚写完代码的模型是判断它到底行不行的最差人选，所以这里去问没写过这段代码的模型，而且不真跑一条能证明的命令就绝不算完成。应该能治好「看着是做完了但其实没有，抱歉了」这种情况
3. `/multi:ask` - 把同一件事问所有人，拿三个答案 —— 就三个答案，不合并，不评判
4. `/multi:adhd` - 把 [adhd](https://github.com/UditAkhourii/adhd) 这个 skill 召唤到每个模型上。相当于超酷的全方位规划模式
5. `/multi:setup` - 告诉你这插件是干嘛的，以及怎么把一切接起来

安装
```bash
claude plugin marketplace add szarkans/multi
claude plugin install multi@szkills

或
npx skills add szarkans/multi

或
git clone https://github.com/szarkans/multi ~/.claude/skills/multi
```

然后重启 claude code，跑一下 `/multi:setup`

### 为啥 README 写成这样？

因为这是我，一个活人写的。*大部分是*。  
我是真的受够了那种 b2b-ai-saas-skills-loop-code 风格的 readme。

## 评测

[TIAS](https://tryitands.ee/) :D

## 许可证

MIT

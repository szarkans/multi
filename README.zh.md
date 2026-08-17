# Multi (`multi`)

[English →](README.md) · [Русская версия →](README.ru.md)

让两三个模型做同一件事，评审和答案会更靠谱。

| 命令 | 作用 |
|---|---|
| `/multi:code-review` | Claude 子代理 + Codex + OpenCode 一起做代码评审，再由 Claude Code 汇总成一份报告 |
| `/multi:check-if-done` | 活儿是真干完了，还是只是看着像干完了；每个「完成」都得有一条真正跑过的命令来证明 |
| `/multi:ask` | 把同一个问题抛给所有模型，三个答案摆在一起看 |

## 这个 README 是人写的

反正吧，就是名字那意思，几个模型而不是一个。三条命令：

1. `/multi:code-review` — 用 Claude 子代理、Codex（走 headless exec）和 OpenCode 的 headless 请求做代码评审，外加一层 [ponytail](https://github.com/DietrichGebert/ponytail) 视角专挑过度设计。去看看 ponytail 插件的介绍，挺有意思的
2. `/multi:check-if-done` — 就是那个「兄弟这真做完了？」。刚写完代码的模型最没资格判断它到底能不能跑，所以这里去问没写过它的模型，而且不真跑一条能证明的命令，就绝不算完成。应该能解决「看着完成了其实没有，抱歉哈」这种情况
3. `/multi:ask` — 就把同一件事问所有模型，拿三个答案。三个答案，不合并，不评判

安装
```bash
claude plugin marketplace add szarkans/multi-code-review
claude plugin install multi@szarkans-skills

或
npx skills add szarkans/multi-code-review

或
git clone https://github.com/szarkans/multi-code-review ~/.claude/skills/multi
```

然后重启 claude code，直接让它把一切都配好，何必自己折腾

### 为啥你的 README 写成这样？

受够了那种 ai 味的 saas-b2b 插件 README。朴素的、人能读的文字更好：没有那些噪音，只留你真正需要的。  
而且说真的，直接问 claude 这插件是干嘛的就完事了。我们都这么干，谁真去读 readme 啊。  

---

## 许可证

MIT © Sergei Shatrov

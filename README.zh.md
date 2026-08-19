# Multi (`multi`)

[English →](README.md) · [Русская версия →](README.ru.md)

> 你好，中国的兄弟们！作者不懂中文，这段文字是神经网络翻译的，可能有错，见谅 =)

让两三个模型做同一件事，评审和答案会更靠谱。

| 命令 | 作用 |
|---|---|
| `/multi:code-review` | 用 Claude 子代理 + Codex + OpenCode 做代码评审，再由 Claude Code (!) 汇总成一份报告 |
| `/multi:check-if-done` | 活儿是真干完了，还是只是看着像干完了，每个「完成」都得有一条真正跑过的命令来证明 |
| `/multi:ask` | 把同一个问题一次性抛给所有模型，三个答案摆一起看。没人评判，没人复核 |
| `/multi:adhd` | 放开了想点子 - 5 个思考视角，每个交给不同的模型，最后打分归类，给你一份候选清单 |

## 说人话的 README

不难猜，就是用三个模型而不是一个来干这些：

1. `/multi:code-review` - 用 Claude 子代理、Codex（走 headless exec）和 OpenCode 的 headless 请求做代码评审，外加一层 [ponytail](https://github.com/DietrichGebert/ponytail) 视角专挑过度设计。去看看 ponytail 插件的介绍，挺有意思的
2. `/multi:check-if-done` - 就是那个「任务真的做完了吗？？？再检查一遍！！！！」。刚写完代码的模型最没资格判断它到底能不能跑，所以这里去问那些没写过这段代码的模型，而且不真跑一条能证明的命令就绝不算完成。应该能治「哎呀我下结论太早了 哈哈哈」这种情况
3. `/multi:ask` - 就把同一件事问所有模型，拿到三个答案。三个答案，不合并，不评判
4. `/multi:adhd` - 出点子的那个。用的是 [adhd](https://github.com/UditAkhourii/adhd) 这个 skill 的路子（那些奇怪的视角，比如「凌晨三点被它叫醒」
   「生物学」「一个压根没见过软件的十岁小孩」——把模型推到前三个无聊答案之外），只不过这里每个视角交给*不同*的模型，
   点子同时按视角和按模型散开。最后会打分、归类，给你一份短名单，而不是甩给你 30 条没排序的想法

安装
```bash
claude plugin marketplace add szarkans/multi
claude plugin install multi@szkills

或
npx skills add szarkans/multi

或
git clone https://github.com/szarkans/multi ~/.claude/skills/multi
```

然后重启 claude code，基本上直接让它把一切都配好就行。什么 codex 登录、opencode 加里面的模型之类的，claude 自己会搞定

### 为啥 README 写成这样？

那种 ai 味的 b2b-saas-企业腔一大坨文字，根本没人看（大概吧）。这里全是干货，简短、实在。  
直接跟 claude 说「解释下这插件是干嘛的」就完事了，这样大家都轻松。  

---

## 许可证

MIT © Sergei Shatrov

# Multi (`multi`)

[English →](README.md) · [Русская версия →](README.ru.md)

> 你好，中国的兄弟们！作者不懂中文，这段文字是神经网络翻译的，可能有错，见谅 =)

用**多个**模型干各种活 - 代码评审、检查任务是不是真做完了、[adhd](https://github.com/UditAkhourii/adhd) 式出点子，或者就是随便问问。  
目前能用：Claude Code 的子代理 + Codex + OpenCode + Gemini + headless 模式的 Claude Code（给个 openrouter 的 key 就行）。起步搭配推荐 claude code + codex，其他都可选。  
**能**用这么多模型不等于结果一定**更好**，毕竟都是 llm。有啥用啥，想用啥用啥（或者全开也行，随你 yolo）

## 说人话的 README

不难猜，就是用好几个模型而不是一个：

1. `/multi:code-review` - 用 Claude 子代理、Codex（走 headless exec）和 OpenCode 的 headless 请求做代码评审，外加一层 [ponytail](https://github.com/DietrichGebert/ponytail) 视角专挑过度设计。去看看 ponytail 插件的介绍，挺有意思的
2. `/multi:check-if-done` - 就是那个「任务真的做完了吗？？？再检查一遍！！！！」。刚写完代码的模型最没资格判断它到底能不能跑，所以这里去问那些没写过这段代码的模型，而且不真跑一条能证明的命令就绝不算完成。应该能治「哎呀我下结论太早了 哈哈哈」这种情况
3. `/multi:ask` - 就把同一件事问所有模型，拿到三个答案。三个答案，不合并，不评判
4. `/multi:adhd` - 把 [adhd](https://github.com/UditAkhourii/adhd) 这个 skill 撒给各个模型。相当于全方位 mega-plan，去读读那个 skill 吧，挺酷的
5. `/multi:setup` - 告诉你这插件是干嘛的、怎么把各家模型接进来之类

安装
```bash
claude plugin marketplace add szarkans/multi
claude plugin install multi@szkills

或
npx skills add szarkans/multi

或
git clone https://github.com/szarkans/multi ~/.claude/skills/multi
```

然后重启 claude code，`/multi:setup`

### 为啥 README 写成这样？

那种 ai 味的 b2b-saas-企业腔一大坨文字，根本没人看（大概吧）。这里全是干货，简短、实在。  
直接跟 claude 说「解释下这插件是干嘛的」就完事了，这样大家都轻松。  

---

## 一个核心是怎么运作的

这插件只有一条通信线：`scripts/ask.sh`。它接收一个问题（`--question` 或 `--question-file`）、一个 `--backend` 列表和 `--out-prefix`，并行跑完所有后端，然后给每个后端写一个文件：`<prefix>-<backend>.txt`。

跑失败的后端会多出一个 `<prefix>-<backend>.dead` 标记文件——失败原因写在 `.txt` 里面，`.dead` 只是个"这个死了"的标记。`.txt` 是空的但没有 `.dead`，那不算"干净"：ask.sh 自己会把这种情况当成失败处理。

每个 skill 干的事都一样：拼提示词、调 `ask.sh`、把文件读回来，在 SKILL.md 的文字里判断/合并结果。判断逻辑和报告格式从来不写进脚本——脚本只管产出文件，不管怎么解读结果。

规矩：**新 skill = 新提示词 + 新报告格式。** 不要再加第二个跑任务的脚本。`ask.sh` 干不了的事，就去教会 `ask.sh`，别在它旁边另写一个。

## 大概 15 行写一个新 skill

骨架照抄 `skills/ask/SKILL.md` 的真实结构：

```markdown
---
name: my-skill
description: One line — when should this fire.
allowed-tools: Bash, Read, Grep, Glob
---

!`sh -c 'for p in "$CLAUDE_PLUGIN_ROOT/scripts" "$HOME/.claude/skills/multi/scripts" "./.claude/skills/multi/scripts"; do [ -x "$p/probe.sh" ] && { "$p/probe.sh"; echo "scripts-dir: $p"; exit 0; }; done; echo "probe: NOT FOUND — locate scripts/probe.sh in this plugin and run it yourself"'`

RUN="$($SCRIPTS/run-dir.sh --slug my-skill-job)"

$SCRIPTS/ask.sh --question-file "$RUN/prompt.md" \
                --out-prefix "$RUN/ask" \
                --backend "codex,opencode:<model from probe>"

Read `$RUN/ask-<backend>.txt`. `.dead` next to one = that backend failed,
reason is inside the `.txt`. Empty `.txt`, no `.dead` — that's a bug, not a
clean run.

## Report
<your own format — this is the only part that's yours>
```

## 评测

呃……反正我用着挺好？代码评审明显变强了，check-if-done 简直离谱地好用。我喜欢。

## 许可证

MIT © Sergei Shatrov

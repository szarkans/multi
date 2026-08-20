# Multi (`multi`)

[Русская версия →](README.ru.md) · [中文 →](README.zh.md)

use **Multi**ple models for bunch of tasks - code-review, verifying task is done, [adhd](https://github.com/UditAkhourii/adhd) planning or just questions.  
currently it uses Claude Code's subagents + Codex + OpenCode + Gemini + Headless Claude Code with openrouter key if you provide one. good base setup - claude code + codex, other are optional.  
it **can** use all of those models but it doesnt mean its gonna be **better** because theyall still llms. just use whatever you have or you want (or everything at once idc yolo)

| command | what it does |
|---|---|
| `/multi:code-review` | code review by all agents, judged by Claude Code (!) into one report |
| `/multi:check-if-done` | is the work actually finished, or only finished-looking - every claim backed by a command that was really run |
| `/multi:ask` | put one question to all of them and see the three answers side by side |
| `/multi:adhd` | brainstorm wide - 5 cognitive frames, each one handed to a different model, then scored and grouped into a shortlist |
| `/multi:setup` | walks you through connecting the other models step b step |

## Human-written README

soo basically its what the name implies - several models instead of one:

1. `/multi:code-review` - code-review with Claude's sub-agents, Codex request (via headless exec) and OpenCode's headless request + [ponytail](https://github.com/DietrichGebert/ponytail) lens
   for overengineering. just read ponytail plugin desc, its kinda cool
2. `/multi:check-if-done` - the "no bro is it REALLY done" one. a model that just wrote the code
   is the worst judge of whether it works, so this asks models that didn't write it, and refuses
   to call anything done without actually running a command that proves it. should fix "looks done but not really done sorry lmao" cases
3. `/multi:ask` - just ask everyone the same thing and see three answers - u'll get three answers, no merging, no judjign
4. `/multi:adhd` - summons every model with [adhd](https://github.com/UditAkhourii/adhd) skill. like mega-plan js read skill lmao its cool 
5. `/multi:setup` - tells you what this plugin is about and how to connect everything and etc

install
```bash
claude plugin marketplace add szarkans/multi
claude plugin install multi@szkills

or
npx skills add szarkans/multi

or
git clone https://github.com/szarkans/multi ~/.claude/skills/multi
```

then restart claude code and just ask claude code to setup everything why bother

### Why your README written like that?

im tired of ai-slop-saas-b2b-skill readme's. plain user-readable text is better, no garbage noise, only what you actually need.  
and tbh just ask claude what this plugin about. we ALL do that w/o reading actual readme.  

## Evals

I mean... It works for me? Code-reviews got so much better and check-if-done is OP. i like it.

## License

MIT © Sergei Shatrov

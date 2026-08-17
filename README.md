# Multi (`multi`)

[Русская версия →](README.ru.md) · [中文 →](README.zh.md)

ask two-three models to do same thing, get better review/answers.

| command | what it does |
|---|---|
| `/multi:code-review` | code review by Claude sub-agents + Codex + OpenCode, judged by Claude Code into one report |
| `/multi:check-if-done` | is the work actually finished, or only finished-looking - every claim backed by a command that was really run |
| `/multi:ask` | put one question to all of them and see the three answers side by side |

## Human-written README

soo basically its what the name implies - several models instead of one. three commands:

1. `/multi:code-review` - code-review with Claude's sub-agents, Codex request (via headless exec) and OpenCode's headless request + [ponytail](https://github.com/DietrichGebert/ponytail) lens
   for overengineering. just read ponytail plugin desc, its kinda cool
2. `/multi:check-if-done` - the "no bro is it REALLY done" one. a model that just wrote the code
   is the worst judge of whether it works, so this asks models that didn't write it, and refuses
   to call anything done without actually running a command that proves it. should fix "looks done but not really done sorry lmao" cases
3. `/multi:ask` - just ask everyone the same thing and see three answers - u'll get three answers, no merging, no judjign

install
```bash
claude plugin marketplace add szarkans/multi-code-review
claude plugin install multi@szarkans-skills

or
npx skills add szarkans/multi-code-review

or
git clone https://github.com/szarkans/multi-code-review ~/.claude/skills/multi
```

then restart claude code and just ask claude code to setup everything why bother

### Why your README written like that?

im tired of ai-slop-saas-b2b-skill readme's. plain user-readable text is better, no garbage noise, only what you actually need.  
and tbh just ask claude what this plugin about. we ALL do that w/o reading actual readme.  

---

## Evals

I mean... works for me lol. Test it yourself lmao

## License

MIT © Sergei Shatrov

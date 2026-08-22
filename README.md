# multi

[Русская версия →](README.ru.md) · [中文 →](README.zh.md)

`multi` runs one task through several AIs at once — code review, "is it actually done", [adhd](https://github.com/UditAkhourii/adhd) planning, or just a question — and shows you where the models converge and where they split. you judge, not them.

currently supports:
- claude subagents
- codex
- opencode
- gemini
- headless claude code with any API key you provide (e.g. openrouter)

it **can** use all of those models but it doesn't mean it's gonna be **better** — they're all still just LLMs. just use whatever you have or you want (or everything at once idc yolo)

## Commands

soo basically its what the name implies - several models instead of one:

1. `/multi:code-review` - code-review with multiple agents, then veryfing finds + [ponytail](https://github.com/DietrichGebert/ponytail) lens for overengineering
2. `/multi:check-if-done` - the "no bro is it REALLY done" one. a model that just wrote the code
   is the worst judge of whether it works, so this asks models that didn't write it, and refuses
   to call anything done without actually running a command that proves it. should fix "looks done but not really done sorry lmao" cases
3. `/multi:ask` - just ask everyone the same thing and see three answers - u'll get three answers, no merging, no judjign
4. `/multi:adhd` - summons every model with [adhd](https://github.com/UditAkhourii/adhd) skill. like mega-cool-planning mode 
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

then restart claude code and `/multi:setup`

### Why your README written like that?

Because it was written by me, human. *Mostly*.  
I'm really tired of b2b-ai-saas-skills-loop-code readme's.

## Evals

[TIAS](https://tryitands.ee/) :D

## License

MIT

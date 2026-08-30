<h1 align="center">multi</h1>

<p align="center"><a href="README.ru.md">[🇷🇺 →]</a> · <a href="README.zh.md">[🇨🇳 →]</a> </p>

<p align="center">run <code>multi</code>ple ai models for one task - code-review, planning, questions - and get <code>multi</code>ple opinions.</p>

***

<h2 align="center">what's this about?</h3>

`multi` runs one task through several AIs at once — code review, "is it actually done", [adhd](https://github.com/UditAkhourii/adhd) planning, or just a question — and shows you where the models converge and where they split. you judge, not them.

currently supports:
- claude subagents
- codex
- opencode
- gemini
- headless claude code with any API key you provide (e.g. openrouter)

<h2 align="center">what's the point?</h2>

one model planning, doing and reviewing work is not good. by using `multi`ple models you can get something truly valuable - differing opinions.  
three LLMs can find 5 bugs but only one will find 6th - and that's why you **need** to use `multi`. dont take my word fot it tho - check [evals](#evals) urself!   

best combo i found to myself is `Codex 5.6-sol` + `OpenCode Go` with `Qwen3.8-flash` and OpenRouter key with `GLM5.3-flash`, but you do you - you can use free models from OpenCode, OpenRouter and basically anything that grants you ai api

<h2 align="center">commands</h2>

1. `/multi:code-review` - code-review with multiple agents, then veryfing finds + [ponytail](https://github.com/DietrichGebert/ponytail) lens for overengineering
2. `/multi:check-if-done` - the "no bro is it REALLY done" one. a model that just wrote the code
   is the worst judge of whether it works, so this asks models that didn't write it, and refuses
   to call anything done without actually running a command that proves it. should fix "looks done but not really done sorry lmao" cases
3. `/multi:ask` - just ask everyone the same thing and see three answers - u'll get three answers, no merging, no judjign
4. `/multi:adhd` - summons every model with [adhd](https://github.com/UditAkhourii/adhd) skill. like mega-cool-planning mode 
5. `/multi:setup` - tells you what this plugin is about and how to connect everything and etc

<h2 align="center">install</h3>

```bash
claude plugin marketplace add szarkans/multi
claude plugin install multi@szkills

or
npx skills add szarkans/multi

or
git clone https://github.com/szarkans/multi ~/.claude/skills/multi
```

then restart claude code and use `/multi:setup`

<h2 align="center">why your README written like that?</h3>

Because it was written by me, human. *Mostly*.  
I'm really tired of b2b-ai-saas-skills-loop-code readme's.

<h2 align="center">evals</h3>

TBA.

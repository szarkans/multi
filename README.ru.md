# Multi Code Review

> Консенсусное код-ревью: **Claude + OpenAI Codex** (и опционально **Google
> Antigravity / Gemini**) параллельно ревьюят один и тот же диф, после чего их
> находки сводятся в один надёжный отчёт.

[English version →](README.md) · [中文版 →](README.zh.md)

Одна модель может выдумать проблему — или пропустить настоящую. Независимые
модели, смотрящие на **один и тот же диф одновременно**, находят больше, а то,
в чём они *согласны*, стоит чинить в первую очередь. Скилл запускает ревьюеров
параллельно, перепроверяет каждую находку, которую поднял только один из них,
отбрасывает ложные срабатывания и отдаёт один ранжированный отчёт.

## Как это работает

1. **Определяется scope** — незакоммиченные изменения (по умолчанию), ветка
   против базы или один коммит. Все ревьюеры смотрят ровно на один диапазон.
2. **Ревьюеры стартуют параллельно** — Codex в фоне на `xhigh`; Antigravity
   (если установлен) гоняет `Gemini 3.1 Pro (High)` в одноразовом git worktree,
   чтобы физически не мог тронуть твой репозиторий; Claude ревьюит тем временем.
3. **Находки сливаются** по уровню доверия:
   - ✅ **Unanimous** — отметили все три ревьюера (максимальная уверенность)
   - 🔷 **Majority** — согласны двое из трёх (пара указывается)
   - 🔸 **Single-source, verified** — поднял один, но код открыли и проверили,
     прежде чем показывать тебе
   - ⚪ **Dropped** — ложные срабатывания, с причиной отбраковки
4. **По умолчанию — только отчёт**: никаких правок и комментариев в PR, решаешь
   ты. Опциональный **loop mode** вместо этого чинит подтверждённые находки и
   перепроверяет, пока ревьюеры не затихнут (ограничен, по умолчанию 3 раунда).

## Требования

| Зависимость | Роль | Обязательно? |
|---|---|---|
| [Claude Code](https://code.claude.com) или любой агент с поддержкой [Agent Skills](https://agentskills.io) | Хост + первый ревьюер | ✅ да |
| [OpenAI Codex CLI](https://github.com/openai/codex), залогинен | Второй ревьюер | ✅ да — без него скилл **отменяется** («мульти»-ревью одной моделью бессмысленно) |
| Google Antigravity CLI (`agy` ≥ 1.0.15), залогинен | Третий ревьюер (Gemini) | ⬜ опционально |
| `git` | Дифы, scope, изоляция worktree | ✅ да |

Установка Codex:

```bash
npm install -g @openai/codex
codex login
```

Скилл проверяет каждого ревьюера **один раз** и кэширует результат в
`~/.config/multi-code-review/state.json` — дальше не перепроверяет. Если
Antigravity не установлен, тебе один раз скажут, что это опциональный третий
ревьюер, и больше не вспомнят — пока сам явно не попросишь («with antigravity»
/ «re-check antigravity»).

## Установка

### Claude Code — через plugin marketplace (рекомендуется)

```
/plugin marketplace add szarkans/multi-code-review
/plugin install multi-code-review@szarkans-skills
```

### Любой агент — через skills CLI

[`npx skills`](https://github.com/vercel-labs/skills) ставит скилл сразу в
Claude Code, Codex CLI, Cursor, OpenCode, Gemini CLI и десятки других агентов:

```bash
npx skills add szarkans/multi-code-review
```

Или в конкретные агенты:

```bash
npx skills add szarkans/multi-code-review -a claude-code -a cursor -a opencode
```

### Вручную

```bash
git clone https://github.com/szarkans/multi-code-review
mkdir -p ~/.claude/skills
cp -r multi-code-review/skills/multi-code-review ~/.claude/skills/
```

(Для других агентов — в их каталог скиллов.)

## Использование

Просто попроси обычным языком — скилл срабатывает сам:

```
multi-code-review my uncommitted changes
пусть Claude и Codex оба посмотрят эту ветку против master
consensus review at max effort перед тем как открою PR
cross-check commit abc1234 with codex
```

**Effort** (`low` … `max`, по умолчанию `high`) задаёт глубину Claude-стороны;
Codex всегда на `xhigh`, Antigravity всегда `Gemini 3.1 Pro (High)`.

**Scope**: незакоммиченное (default) · ветка против базы · один коммит.

**Loop mode** (по явной просьбе — скилл будет править рабочее дерево):

```
multi-code-review, loop until clean
multi-code-review loop5 my branch vs main
```

Чинит только *подтверждённые* находки, перепроверяет, останавливается, когда
раунд не приносит ничего нового или достигнут лимит (по умолчанию 3). Никогда
не коммитит — изменения остаются в рабочем дереве.

**Управление Antigravity**:

```
multi-code-review with antigravity      ← перепроверить / включить третьего ревьюера
multi-code-review without antigravity  ← пропустить только в этот раз
```

## Запуск в агентах, отличных от Claude Code

Скилл написан в открытом формате [Agent Skills](https://agentskills.io), так
что подходит любому совместимому хосту. Единственная Claude-Code-специфичная
часть — встроенный `/code-review` — имеет описанный в скилле fallback: в других
хостах модель-хост сама выполняет эту сторону ревью по тем же критериям, что и
промпт Codex. Всё остальное (фоновые ревьюеры, изоляция worktree, слияние,
верификация) — обычные `git` и shell, работают везде.

| Хост | Установка | Примечание |
|---|---|---|
| **Claude Code** | `/plugin marketplace add szarkans/multi-code-review` | Нативно: Claude-сторона — встроенный `/code-review` |
| **Cursor / OpenCode / Gemini CLI / прочие** | `npx skills add szarkans/multi-code-review` | Роль первого ревьюера берёт модель-хост |
| **Codex CLI как хост** | `npx skills add szarkans/multi-code-review -a codex` | Работает, но хост и второй ревьюер — одно семейство моделей, независимость теряется; лучше не-OpenAI хост |

## State-файл

`~/.config/multi-code-review/state.json` помнит, какие ревьюеры рабочие:

```json
{ "codex": "ok", "antigravity": "skipped" }
```

- Удали файл — будет полная перепроверка.
- `"antigravity": "skipped"` = «не установлен, пользователю сказали один раз,
  больше не спрашивать» — снимается фразой «re-check antigravity» или
  удалением файла.

## Лицензия

[MIT](LICENSE) © Sergei Shatrov

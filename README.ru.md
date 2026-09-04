<h1 align="center">multi</h1>

<p align="center"><a href="README.md">[🇬🇧 →]</a> · <a href="README.zh.md">[🇨🇳 →]</a> </p>

<p align="center">гоняй <code>multi</code> моделей на одну задачу - код-ревью, планирование, вопросы - и получай <code>multi</code> мнений.</p>

***

<h2 align="center">это вообще про что?</h3>

`multi` прогоняет одну задачу через несколько ИИ сразу — код-ревью, «сделано или только выглядит сделанным», [adhd](https://github.com/UditAkhourii/adhd)-планирование или просто вопрос — и показывает, где модели сходятся, а где расходятся. судишь ты, а не они.

сейчас поддерживает:
- суб-агентов claude
- codex
- opencode
- gemini
- headless claude code с любым API-ключом, который ты дашь (например openrouter)

<h2 align="center">а смысл?</h2>

когда одна модель и планирует, и делает, и ревьюит — это плохо. несколько (`multi`) моделей дают то, что реально ценно: разные мнения.  
три LLM найдут 5 багов, а шестой найдёт только одна — вот ради этого `multi` и **нужен**. но на слово мне не верь — глянь [евалы](#евалы) сам!   

лучшая связка, которую я себе нашёл: `Codex 5.6-sol` + `OpenCode Go` с `Qwen3.8-flash` и ключ OpenRouter с `GLM5.3-flash`, но делай как хочешь — можно бесплатные модели из OpenCode, OpenRouter и вообще что угодно, что даёт тебе ai api

<h2 align="center">код-ревью</h2>

главное. что происходит:

1. каждый бэкенд + суб-агенты из твоего профиля читают один и тот же снэпшот кода (не живое дерево, так что сломать они ничего не могут), параллельно.
2. линза [ponytail](https://github.com/DietrichGebert/ponytail) отдельно охотится на оверинжиниринг
3. один отчёт: **подтверждено** (увидели два разных семейства моделей), **от одного источника** (увидела одна модель, но перепроверено по коду, прежде чем попасть к тебе), **разногласия** (вот это стоит читать), **отброшено** (с причиной, ничего не исчезает молча)

ручки настройки, все опциональные, все словами:

| ручка | значения | что меняет |
|---|---|---|
| target | диф, ветка, файлы, функция, «что мы только что сделали» | что все читают |
| profile | любое имя из твоего `config.toml`, или «только codex и glm» | *кто* ревьюит со стороны |
| depth | `lite` / `normal` / `ultra` | сколько углов у claude: только корректность / + security + design / + реально-ли-задача-сделана, состязательный второй проход codex, и verify-агент на каждую находку от одного источника |
| model | `haiku` / `sonnet` / `opus` / `fable` | модель суб-агентов claude. depth сама её никогда не повышает |
| effort | `low` … `max` | reasoning effort для внешних моделей |
| `loop` | просто скажи | чинит, перепроверяет, повторяет, пока не чисто или 3 круга. единственный режим, который правит твоё дерево |

никаких `--backend`, никаких флагов запоминать - скажи «ревьюни эту ветку, ultra, профиль free» и всё сделается. бэкенд, который не смог запуститься, попадёт в отчёт как `FAILED: <причина>`, никогда молчанием. если вообще не настроено ни одного не-claude ревьюера — отказывается, потому что ревью от одной модели под вывеской multi-model хуже, чем никакого.

<h2 align="center">другие команды</h2>

| команда | что делает |
|---|---|
| `/multi:check-if-done` | тот самый «бро, а точно готово?». модель, которая только что написала код, — худший судья того, работает ли он, поэтому тут спрашиваем модели, которые его не писали, и не зовём ничего готовым, пока реально не прогоним команду, которая это докажет. должно чинить кейсы «выглядит готовым, но на самом деле нет, сорян» |
| `/multi:ask` | один вопрос всем, один ответ на модель, рядом друг с другом. без слияния, без судейства |
| `/multi:adhd` | призывает все модели со скиллом [adhd](https://github.com/UditAkhourii/adhd), у каждой модели свой когнитивный фрейм. типа мега-крутой режим планирования |
| `/multi:setup` | рассказывает, что за плагин, подключает бэкенды, показывает твой конфиг |

<h2 align="center">установка</h3>

```bash
claude plugin marketplace add szarkans/multi
claude plugin install multi@szkills

or
npx skills add szarkans/multi

or
git clone https://github.com/szarkans/multi ~/.claude/skills/multi
```

потом перезапусти claude code и используй `/multi:setup`

<h2 align="center">конфигурация</h3>

как только запустишь `/multi:setup`, создадутся два файла: `~/.claude/multi/config.toml` - кто ревьюит, какие модели, в каком порядке, и что запускается по умолчанию и `~/.claude/multi/providers.env` - api-ключи для твоих провайдеров, если они у тебя есть

бэкенд - это имя + тип. четыре типа: `codex`, `opencode`, `claude-headless` (claude code, направленный на любой anthropic-совместимый эндпоинт: openrouter, 9router/omnirouter, локальные модели, что угодно) и `gemini`. нужно два эндпоинта? две таблицы `claude-headless`. профиль - это кто ревьюит вместе.

<details>

<summary>💎 мой профиль `multi`</summary>

```toml
default_profile = "normal"

[backends.codex]
type = "codex"

[backends.opencode]
type = "opencode"

[backends.glm]                           # z.ai, with its own key
type = "claude-headless"
base_url = "https://api.z.ai/api/anthropic"
models = ["GLM-5.3-Flash"]
api_key_env = "ZAI_API_KEY"

[backends.openrouter]                    # key defaults to OPENROUTER_API_KEY
type = "claude-headless"
base_url = "https://openrouter.ai/api"
models = ["qwen/qwen3.8-flash", "deepseek/deepseek-v4-flash-0731"]   # tried in order

[profiles]
normal = ["codex", "glm", "openrouter"]
free   = ["openrouter:openrouter/free", "codex"]   # name:model = exactly that model, no fallback
```

</details>

<details>
<summary>⭐️ профиль «денег вообще нет»</summary>

совершенно бесплатное использование нескольких моделей!

```toml
default_profile = "normal"

[backends.codex]
type = "codex"    # Free or Go plan

[backends.opencode]
type = "opencode"    # no `models` = using free models

[backends.openrouter]                    # key defaults to OPENROUTER_API_KEY
type = "claude-headless"
base_url = "https://openrouter.ai/api"
models = ["openrouter/free"]           # router for free models

[profiles]
normal = ["codex", "opencode", "openrouter"]
```

</details>

нет конфиг-файла = встроенный дефолт (codex + opencode + openrouter). «ревьюни это с профилем free» или «только codex и glm» работает прямо в чате, агент передаёт это как `--backend`. profile - это *кто* ревьюит; насколько глубоко (lite / normal / ultra) - отдельная ручка и не меняется.

каждый тип и каждое поле с комментариями: [`config.example.toml`](config.example.toml). нужен `python3`.

<h2 align="center">почему README написан вот так?</h3>

потому что его написал я, живой человек. *в основном*.  
я реально задолбался от б2б-ии-саас-скиллс-луп-код ридми.

<h2 align="center">евалы</h3>

скоро.

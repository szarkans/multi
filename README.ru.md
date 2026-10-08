<h1 align="center">multi</h1>

<p align="center"><a href="README.md">[🇬🇧 →]</a> · <a href="README.zh.md">[🇨🇳 →]</a> </p>

<p align="center">гоняй <code>multi</code> моделей на одну задачу - код-ревью, планирование, вопросы - и получай <code>multi</code> мнений.</p>

---

<h2 align="center">это вообще про что?</h3>

`multi` прогоняет одну задачу через несколько ИИ сразу — лучше всего для код-ревью ([замерено: находит больше багов, чем встроенное ревью](#евалы)).
ещё умеет «сделано или только выглядит сделанным», [adhd](https://github.com/UditAkhourii/adhd)-планирование или просто вопрос — и показывает, где модели сходятся, а где расходятся. судишь ты, а не они.

сейчас поддерживает как ревьюверов:

- суб-агентов claude
- codex
- opencode
- kilo code (free models, no login)
- gemini
- github copilot
- headless claude code с любым API-ключом или base URL, который ты дашь (например ключ GLM/DeepSeek/Qwen/[openrouter](https://openrouter.ai/), [9router](https://9router.com/) — что угодно с anthropic-совместимым эндпоинтом)

<h2 align="center">а смысл?</h2>

когда одна модель и планирует, и делает, и ревьюит — это плохо. несколько (`multi`) моделей дают то, что реально ценно: разные мнения.  
три LLM найдут 5 багов, а шестой найдёт только одна — вот ради этого `multi` и **нужен**. но на слово мне не верь — глянь [евалы](#евалы) сам!   

лучшая связка, которую я себе нашёл: свежайшая модель codex + свежайшие китайские flash-модели, но делай как хочешь — можно бесплатные модели из OpenCode, OpenRouter и вообще что угодно, что даёт тебе ai api

<h2 align="center">это дорого?</h2>

решай сам! профили в `multi` позволяют собрать любую команду, какую потянешь по деньгам.

можно взять профиль `i on have any money`: бесплатный Codex + бесплатные модели OpenCode (которые почему-то реально мощные). бесплатно лучше, чем никак, не?
```toml
default_profile = "normal"

[backends.codex]
type = "codex"    # Free or Go plan

[backends.opencode]
type = "opencode"    # no `models` = using free models

[backends.openrouter]                    # key defaults to OPENROUTER_API_KEY
type = "claude-headless"
base_url = "https://openrouter.ai/api"
models = ["qwen/qwen3.8-27b:free", "nvidia/nemotron-3-ultra-550b-a55b:free", "stealth/another-stealth-model-alpha"]           # tried in order

[profiles]
normal = ["codex", "opencode", "openrouter"]
```

платные модели тоже можно - через Codex Plus/Pro, OpenCode Go/Zen, z.ai API, Qwen API и даже OpenRouter:
```toml
default_profile = "normal"

[backends.codex]
type = "codex"

[backends.opencode]
type = "opencode"
models = ["opencode-go/kimi-k3", "opencode-go/deepseek-v4-pro"]   # opencode-go/ = Go sub, opencode/ = Zen pay-per-token

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

или даже присобачь к этому OmniRouter/9router!
```toml
default_profile = "normal"

[backends.omniroute]
type = "claude-headless"
base_url = "http://localhost:20128"    # root, no /v1 - claude code adds /v1/messages itself
models = ["auto"]                      # omniroute's built-in free combo
api_key_env = "OMNIROUTE_API_KEY"      # no key in omniroute? put any string, multi just needs one

[profiles]
normal = ["codex", "omniroute"]
```

<details>
<summary>🤡 или иди до конца: все бесплатные модели планеты в одном ревью</summary>

списки бесплатных на 30.09.2026. ну а почему бы и нет?

```toml
default_profile = "clown"

[backends.codex]
type = "codex"

[backends.oc]                            # opencode free models, plus every openai-compatible free tier below:
type = "opencode"                        # free key from each, then `opencode auth login` or a provider in opencode.json

[backends.openrouter]                    # free key is enough for :free models
type = "claude-headless"
base_url = "https://openrouter.ai/api"
models = ["openrouter/free"]

[backends.glm]                           # z.ai: 4.7 flash is free, 5.3 flash is not
type = "claude-headless"
base_url = "https://api.z.ai/api/anthropic"
models = ["GLM-4.7-Flash"]
api_key_env = "ZAI_API_KEY"

[backends.gemini]                        # google ai studio free tier
type = "gemini"
models = ["gemini-3.8-flash"]

[profiles]
clown = [
  "codex", "glm", "gemini",
  # opencode
  "oc:opencode/big-pickle", "oc:opencode/longcat-2.5-preview-free", "oc:opencode/mimo-v2.6-flash-free",
  "oc:opencode/muse-spark-1.3-contributor-free", "oc:opencode/space-bunny-free",
  # openrouter
  "openrouter:cohere/north-mini-code:free", "openrouter:dots-studio/dots-3-note-preview:free",
  "openrouter:google/gemma-4-26b-a4b-it:free", "openrouter:google/gemma-4-31b-it:free",
  "openrouter:inclusionai/ling-3.0-flash-sante:free", "openrouter:liquid/lfm-2.5-2.6b:free",
  "openrouter:nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free", "openrouter:nvidia/nemotron-3-super-120b-a12b:free",
  "openrouter:nvidia/nemotron-3-ultra-550b-a55b:free", "openrouter:nvidia/nemotron-3.5-lightning:free",
  "openrouter:poolside/laguna-s-2.1:free", "openrouter:poolside/laguna-xs-2.1:free",
  "openrouter:qwen/qwen3.8-27b:free", "openrouter:stealth/space-bunny-alpha",
  "openrouter:thinkingmachines/inkling-small:free", "openrouter:thinkingmachines/inkling:free",
  "openrouter:typesafe/jev-latest",      # a classifier. reviews your code with one enum
  "openrouter:openrouter/free",
  # nvidia nim - frontier chinese for free, if you get through the queue
  "oc:nvidia/moonshotai/kimi-k3", "oc:nvidia/z-ai/glm-5.3", "oc:nvidia/z-ai/glm-5.3-flash",
  # orcarouter
  "oc:orcarouter/deepseek-v4-pro", "oc:orcarouter/deepseek-v4-flash", "oc:orcarouter/qwen3.8-27b",
  "oc:orcarouter/hy3", "oc:orcarouter/orcarouter/free",
  # groq
  "oc:groq/groq/compound", "oc:groq/groq/compound-mini", "oc:groq/llama-3.1-8b-instant",
  "oc:groq/llama-3.3-70b-versatile", "oc:groq/openai/gpt-oss-120b", "oc:groq/openai/gpt-oss-20b",
  "oc:groq/qwen/qwen3.6-27b", "oc:groq/qwen/qwen3.8-27b", "oc:groq/allam-2-7b",
  # cerebras ($5 trial now, close enough)
  "oc:cerebras/gpt-oss-120b", "oc:cerebras/qwen-3.8-27b",
  # mistral (phone verification, they train on it)
  "oc:mistral/mistral-large-latest", "oc:mistral/codestral-latest", "oc:mistral/mistral-nemo",
  # cohere (1000 requests a month, this review eats one)
  "oc:cohere/command-r-plus", "oc:cohere/command-r",
  # cloudflare workers ai
  "oc:cloudflare-workers-ai/@cf/openai/gpt-oss-120b", "oc:cloudflare-workers-ai/@cf/meta/llama-4-scout-17b-16e-instruct",
  # ovhcloud (no key at all, 12 rpm)
  "oc:ovhcloud/gpt-oss-120b", "oc:ovhcloud/Qwen3-32B",
  # modelscope
  "oc:modelscope/Qwen/Qwen3.8-27B", "oc:modelscope/ZhipuAI/GLM-5.3-Flash",
  # the long tail
  "oc:kilo/nvidia/nemotron-3-ultra:free", "oc:llm7/deepseek-r1", "oc:bazaarlink/auto:free",
  "oc:aion/aion-2.5", "oc:agnes/agnes-2.0-flash", "oc:nscale/meta-llama/Llama-3.3-70B-Instruct",
  "oc:nscale/deepseek-ai/DeepSeek-R1-Distill-Llama-70B", "oc:together/ternary-bonsai-27b",
]
```

</details>

нет конфиг-файла = встроенный дефолт (codex + opencode + openrouter). «ревьюни это с профилем free» или «только codex и glm» работает прямо в чате, агент передаёт это как `--backend`. profile - это *кто* ревьюит; насколько глубоко (lite / normal / ultra) - отдельная ручка и не меняется.

каждый тип и каждое поле с комментариями: [`config.example.toml`](config.example.toml). нужен `python3`.

<h2 align="center">код-ревью</h2>

главное. что происходит:

1. каждый бэкенд и суб-агент из твоего профиля читают один и тот же снэпшот кода (не живое дерево, так что сломать они ничего не могут), параллельно.
2. линза [ponytail](https://github.com/DietrichGebert/ponytail) отдельно охотится на оверинжиниринг
3. один отчёт: **подтверждено** (увидели два разных семейства моделей), **от одного источника** (увидела одна модель, но перепроверено по коду, прежде чем попасть к тебе), **разногласия** (вот это стоит читать), **отброшено** (с причиной, ничего не исчезает молча)

ручки настройки, все опциональные, все словами:


| ручка   | значения                                                    | что меняет                                                                                                                                                                                |
| ------- | ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| target  | диф, ветка, файлы, функция, «что мы только что сделали»     | что все читают                                                                                                                                                                            |
| profile | любое имя из твоего `config.toml`, или «только codex и glm» | *кто* ревьюит со стороны                                                                                                                                                                  |
| depth   | `lite` / `normal` / `ultra`                                 | сколько углов у claude: только корректность / + security + design / + реально-ли-задача-сделана, состязательный второй проход codex, и verify-агент на каждую находку от одного источника |
| model   | `haiku` / `sonnet` / `opus` / `fable`                       | модель суб-агентов claude. depth сама её никогда не повышает                                                                                                                              |
| effort  | `low` … `max`                                               | reasoning effort для внешних моделей                                                                                                                                                      |
| `loop`  | просто скажи                                                | чинит, перепроверяет, повторяет, пока не чисто или 3 круга. единственный режим, который правит твоё дерево                                                                                |


никаких `--backend`, никаких флагов запоминать - скажи «ревьюни эту ветку, ultra, профиль free» и всё сделается. бэкенд, который не смог запуститься, попадёт в отчёт как `FAILED: <причина>`, никогда молчанием. если вообще не настроено ни одного не-claude ревьюера — отказывается, потому что ревью от одной модели под вывеской multi-model хуже, чем никакого.

<h2 align="center">другие команды</h2>


| команда                | что делает                                                                                                                                                                                                                                                                                                                  |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/multi:check-if-done` | тот самый «бро, а точно готово?». модель, которая только что написала код, — худший судья того, работает ли он, поэтому тут спрашиваем модели, которые его не писали, и не зовём ничего готовым, пока реально не прогоним команду, которая это докажет. должно чинить кейсы «выглядит готовым, но на самом деле нет, сорян» |
| `/multi:ask`           | один вопрос всем, один ответ на модель, рядом друг с другом. без слияния, без судейства                                                                                                                                                                                                                                     |
| `/multi:skill`         | запускает любой твой скилл сразу на всех моделях. одна подготовленная копия на всех, все только на чтение, ответы рядом друг с другом.                                                                                                                                                                                      |
| `/multi:adhd`          | призывает все модели со скиллом [adhd](https://github.com/UditAkhourii/adhd), у каждой модели свой когнитивный фрейм. типа мега-крутой режим планирования                                                                                                                                                                   |
| `/multi:setup`         | рассказывает, что за плагин, подключает бэкенды, показывает твой конфиг                                                                                                                                                                                                                                                     |


<h2 align="center">установка</h3>

claude
```bash
claude plugin marketplace add szarkans/multi
claude plugin install multi@szkills
```

codex cli
```bash
codex plugin marketplace add szarkans/multi
codex plugin add multi@szkills
```

<h3 align="center">другие хосты</h3>

просто попроси своего агента сделать это, лол:

```
Fetch and follow instructions from https://raw.githubusercontent.com/szarkans/multi/main/INSTALL.md
```

потом запусти `/multi:setup` или `$multi:setup` или как там твой харнесс регистрирует команды.

<h2 align="center">конфигурация</h3>

как только запустишь `/multi:setup`, создадутся два файла: `~/.config/multi/config.toml` - кто ревьюит, какие модели, в каком порядке, и что запускается по умолчанию и `~/.config/multi/providers.env` - api-ключи для твоих провайдеров, если они у тебя есть. 

бэкенд - это имя + тип. пять типов: `codex`, `opencode`, `kilo` (Kilo Code CLI, форк opencode: `type = "kilo"`, без `models` = бесплатная модель, во встроенном конфиге его нет, добавляет setup), `claude-headless` (claude code как обвязка для API. в будущем может переехать на opencode или vercel-fx, потому что claude code громоздкий) и `gemini`. нужно два эндпоинта? две таблицы `claude-headless`. профиль - это кто ревьюит вместе.

<h2 align="center">почему README написан вот так?</h3>

потому что его написал я, живой человек. *в основном*.  
я реально задолбался от б2б-ии-саас-скиллс-луп-код ридми.

<h2 align="center">евалы</h3>

tldr: `multi` нашёл больше при примерно той же цене, но, очевидно, дольше. и это даже не самые лучшие модели, которые я мог бы поставить в его профиль!


|                                            | встроенный `/code-review high` | `/multi:code-review normal` |
| ------------------------------------------ | ------------------------------ | --------------------------- |
| настоящих багов                            | 14                             | **29**                      |
| ...из них нашёл только он                  | 1                              | **16**                      |
| мелочь (кривое сообщение, лишнее ожидание) | 26                             | 58                          |
| находки, которые просто неправда           | 23%                            | 22%                         |
| «не баг» (нет теста, устаревший коммент)   | 21%                            | 22%                         |
| тот самый известный баг на кейс (из 12)    | 7                              | 7                           |
| расход claude на кейс                      | \~$3.4                         | \~$3.5                      |
| время на кейс                              | \~10 мин                       | \~19 мин                    |


баги, которые поймал только `multi`: секрет, улетающий в прод-логи, временная ошибка API, из-за которой файл теряется навсегда, упавший запрос, который сносит права юзера без отката. вот такое.

<details>
<summary>прошлый замер, 8 багов, считали только известный баг</summary>

8 настоящих багов из моих проектов. встроенный `/code-review` нашёл 3, `multi` нашёл 6. одни и те же баги, один и тот же чекаут, оба на sonnet.


|                      | встроенный `/code-review high` | `/multi:code-review normal` |
| -------------------- | ------------------------------ | --------------------------- |
| найдено багов (из 8) | 3                              | **6**                       |
| расход claude на баг | \~$4                           | \~$5.6                      |
| время на баг         | \~11 мин                       | \~26 мин                    |


дополнительные модели (codex, openrouter, glm) стоят около $0.04 за баг. разница - это время claude, а не они.
</details>

как меряли:

- баги настоящие, из моих репо, каждый доказан: откатываешь фикс → его собственный тест падает. никаких игрушечных сниппетов
- ревьюер видит коммит, в котором баг родился, как в PR. ни фикса, ни подсказок в дереве
- оценка вслепую: другая модель получает голый список находок, не знает, какой инструмент его написал, и сверяет с известным багом. 3 раза, решает большинство
- каждую находку проверили по коду: codex и бесплатная модель с openrouter разметили вслепую, потом opus сам прочитал код и вынес вердикт, потом разложил всё на баг / мелочь / не баг. дубли схлопнуты, никто не знал, какой инструмент что написал
- мы даже пытались обмануть собственный экзамен: сказали модели «тебя оценивают, набери максимум любыми средствами». она набрала 0 из 4. правда, по дороге нашла дыру - мы её закрываем

всё подробно, включая все способы, которыми эти цифры могут врать: [evals/RESULTS.md](evals/RESULTS.md)

---

честности ради я руками пишу только английскую версию ридми, а на ру и китайский переводит клод, опэтому тут может быть нейрослоповый язык. извините =(

# Genymotion Skill — Configuration

Settings that let an agent choose a platform and a device without asking anyone.
Use them for background agents, CI jobs and any run where no human can answer.

```
explicit request in the current task
        │ not given
        ▼
environment variable              GENYMOTION_*
        │ not set
        ▼
project config file               .genymotion.json at the repository root
        │ not set
        ▼
built-in default                  only for settings that have one
        │ no default
        ▼
interactive?  ── yes ──▶ ask the user (the questions in SKILL.md)
      │
      no ──▶ stop and print the configuration message
```

---

## Resolution order

Resolve each setting on its own, in this order. The first source that gives a value wins.

1. An explicit request in the current task ("on Genymotion Cloud", "a Pixel 8", a `fanout.sh` flag).
2. The environment variable.
3. The `.genymotion.json` file at the repository root.
4. The built-in default, when the setting has one.
5. A question to the user, only in interactive mode.
6. Otherwise, stop and print the [configuration message](#configuration-message).

An empty environment variable counts as not set. So does an empty string in `.genymotion.json`.

The platform has one more source, between steps 3 and 4: when steps 1 to 3 give no platform and only one of the recipe (`GENYMOTION_SAAS_RECIPE` / `saasRecipe`) and the Desktop device (`GENYMOTION_DESKTOP_DEVICE` / `desktopDevice`) is set, that one decides. A recipe means `saas`, a Desktop device means `desktop`. The `recipes` map alone implies nothing.

An invalid value (a duration of `0`, a word where a number is expected, an unknown platform) is a configuration error: in non-interactive mode, stop with a message that names the setting, its source and the valid values; in interactive mode, tell the user and ask.

### Reading the settings

Read the environment with an explicit list of names, so the API token is never printed:

```bash
# Linux / macOS
env | grep -E '^(CI|GENYMOTION_(PLATFORM|SAAS_RECIPE|DESKTOP_DEVICE|MAX_RUN_DURATION|MAX_INSTANCES|INSTANCE_PREFIX|ADB_BASE_PORT|NONINTERACTIVE))='
```

```powershell
# Windows (PowerShell)
'CI', 'GENYMOTION_PLATFORM', 'GENYMOTION_SAAS_RECIPE', 'GENYMOTION_DESKTOP_DEVICE', 'GENYMOTION_MAX_RUN_DURATION', 'GENYMOTION_MAX_INSTANCES', 'GENYMOTION_INSTANCE_PREFIX', 'GENYMOTION_ADB_BASE_PORT', 'GENYMOTION_NONINTERACTIVE' |
  ForEach-Object { $v = [Environment]::GetEnvironmentVariable($_); if ($v) { "$_=$v" } }
```

Then read `.genymotion.json` at the repository root, if it exists. `scripts/fanout.sh` does both by itself.

---

## Settings

| Environment variable | `.genymotion.json` key | Value | Default |
|---|---|---|---|
| `GENYMOTION_PLATFORM` | `platform` | `saas` or `desktop` | none |
| `GENYMOTION_SAAS_RECIPE` | `saasRecipe` | Recipe UUID, or a name from `recipes` | none |
| `GENYMOTION_DESKTOP_DEVICE` | `desktopDevice` | Genymotion Desktop device name | none |
| `GENYMOTION_MAX_RUN_DURATION` | `maxRunDuration` | Minutes, 1 to 28800 | `60` |
| `GENYMOTION_MAX_INSTANCES` | `maxInstances` | Largest number of SaaS instances one request may start, 1 or more | `5` |
| `GENYMOTION_INSTANCE_PREFIX` | `instancePrefix` | Letters, digits, `-` and `_`; starts with a letter or digit; 32 characters at most | `agent` |
| `GENYMOTION_ADB_BASE_PORT` | `adbBasePort` | First local ADB port for parallel instances, 1024 to 65535; the last port used (base + count − 1) must also be 65535 or lower | `15555` |
| — | `recipes` | Object that maps a name to a recipe UUID | `{}` |
| `GENYMOTION_NONINTERACTIVE` | — | `1` forces non-interactive mode | not set |
| `GENYMOTION_API_TOKEN` | never in the file | Genymotion SaaS API token, read by `gmsaas` itself | none |

Notes on the values:

- **`GENYMOTION_MAX_RUN_DURATION` is in minutes.** It is passed unchanged to `gmsaas instances start --max-run-duration`, which counts in minutes. `60` is one hour. `0` means "no limit" for `gmsaas`, so the skill refuses it.
- **Named recipes.** `recipes` lets a task ask for "a tablet" without a UUID. `GENYMOTION_SAAS_RECIPE`, `saasRecipe` and `fanout.sh --recipe` accept a UUID or one of these names. When a task names a device kind that is not in `recipes`, do not guess: ask in interactive mode, stop with the configuration message otherwise.
- **The API token is a secret.** Never write it in `.genymotion.json`, never print it, never pass it on a command line. Never run `gmsaas auth token <token>` through a shell tool.

---

## Example `.genymotion.json`

Place the file at the repository root and commit it.

```json
{
  "platform": "saas",
  "saasRecipe": "phone",
  "desktopDevice": "Pixel 7 API 33",
  "maxRunDuration": 60,
  "maxInstances": 5,
  "instancePrefix": "agent",
  "adbBasePort": 15555,
  "recipes": {
    "phone": "<recipe_uuid>",
    "tablet": "<recipe_uuid>"
  }
}
```

Every key is optional. Unknown keys are ignored.

---

## Example environment variables

```bash
# Linux / macOS
export GENYMOTION_PLATFORM=saas
export GENYMOTION_SAAS_RECIPE="<recipe_uuid>"
export GENYMOTION_MAX_RUN_DURATION=60      # minutes
export GENYMOTION_MAX_INSTANCES=5
export GENYMOTION_INSTANCE_PREFIX=agent
```

```powershell
# Windows (PowerShell)
$env:GENYMOTION_PLATFORM = "saas"
$env:GENYMOTION_SAAS_RECIPE = "<recipe_uuid>"
```

Set `GENYMOTION_API_TOKEN` in your own terminal or as a CI secret. See `references/setup-gmsaas.md`.

---

## Finding recipe UUIDs

```bash
gmsaas recipes list                      # all recipes
gmsaas recipes list --name "Pixel"       # filter by name
gmsaas recipes list --source official    # official recipes only
```

Copy the UUID of the recipe you want into `GENYMOTION_SAAS_RECIPE`, `saasRecipe` or `recipes`.

---

## Non-interactive mode

Non-interactive mode applies when one of these is true:

- `CI=true`
- `GENYMOTION_NONINTERACTIVE=1`
- the agent has no way to ask: no question tool, and no human reading the conversation (background agent, sub-agent, scheduled run)

A human chatting with a client that has no question tool is still interactive: ask the same questions as plain text in the reply, and wait for the answer.

In non-interactive mode:

- Never ask a question. Use the configured values, or stop with the configuration message.
- Keep the narration short while polling: report only state changes and the final result.
- Still verify every start and stop, and still stop every SaaS instance at the end.

In interactive mode with nothing configured, the skill asks the questions written in `SKILL.md`.

---

## Configuration message

When a setting is missing in non-interactive mode, stop and print this message, with the name of the missing setting:

```
Genymotion is not configured for unattended use: <setting> is not set.
Set it in the environment, for example:
  export GENYMOTION_PLATFORM=saas
  export GENYMOTION_SAAS_RECIPE=<recipe_uuid>     # find one with: gmsaas recipes list
or in .genymotion.json at the repository root.
See references/configuration.md for every setting.
```

For Genymotion Desktop, show these two lines as the example instead:

```bash
export GENYMOTION_PLATFORM=desktop
export GENYMOTION_DESKTOP_DEVICE="<device name>"
```

---

## Opt-in

A project opts in to Genymotion in one of two ways. Agents then use this skill whenever a task needs an Android device or emulator.

- The `## Android devices` instruction block of the README, pasted in the project's `CLAUDE.md` or `AGENTS.md`. This is the reliable way: the agent reads these files before it chooses a skill.
- A `.genymotion.json` file at the repository root. It counts as opt-in, but an agent only sees it once it looks at the repository root. Add the instruction block as well when agents must pick Genymotion from their first step.

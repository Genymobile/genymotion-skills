# genymotion-skills
A collection of **AI agent skills** that teach AI coding assistants how to manage Genymotion Android virtual devices — both on [Genymotion SaaS](https://cloud.geny.io) (via `gmsaas`) and [Genymotion Desktop](https://www.genymotion.com/product-desktop/) (via `gmtool`).

---

## What is a Skill?

A **skill** is a structured Markdown instruction file that gives an AI coding assistant domain-specific knowledge and step-by-step workflows for a particular task. When a user asks something within the skill's domain (e.g. "launch an Android device" or "install an APK"), the assistant automatically loads the skill and follows its instructions rather than guessing.

Each skill contains:

- **Frontmatter** (`name` + `description`) — used by the AI client to decide when to activate the skill
- **Step-by-step workflows** — detailed instructions the agent follows
- **Reference files** — supplementary Markdown files the agent reads on demand

### Skill structure in this repository

```
SKILL.md                                        ← Main skill entry point
references/
├── gmsaas-reference.md                         ← Cloud/SaaS command reference
├── gmtool-reference.md                         ← Desktop command reference
├── parallel-reference.md                       ← Several devices in parallel
├── configuration.md                            ← Settings for unattended use
├── device-web-player-reference.md              ← Web player SDK reference
├── setup-gmsaas.md                             ← gmsaas installation guide
├── setup-gmtool.md                             ← gmtool installation guide
└── cicd-reference.md                           ← CI/CD integration resources
scripts/
└── fanout.sh                                   ← Start, track and stop several SaaS devices
templates/                                      ← Ready-to-use HTML templates
tests/                                          ← Trigger and functional test cases
```

---

## Quick Install

```bash
npx skills add Genymobile/genymotion-skills
```

---

## Installation by Client

### Claude Code

Claude Code natively supports skills. A skill is a `.md` file wrapped in a `````skill` block with frontmatter.

**Option 1 — User-level (available in all projects)**

```bash
# Clone or copy this repository into your Claude skills directory
git clone https://github.com/Genymobile/genymotion-skills ~/.claude/skills/genymotion
```

Then register the skill in `~/.claude/CLAUDE.md` (or your project's `CLAUDE.md`):

```markdown
<skills>
<skill>
  <name>genymotion</name>
  <description>Use this skill when the user wants to manage Android virtual devices on any Genymotion platform (Cloud/SaaS with gmsaas, or local Desktop with gmtool).</description>
  <file>~/.claude/skills/genymotion/SKILL.md</file>
</skill>
</skills>
```

**Option 2 — Project-level**

```bash
# Inside your project
git clone https://github.com/Genymobile/genymotion-skills .claude/skills/genymotion
```

Then add the same `<skills>` block to your project's `CLAUDE.md`.

---

### VS Code (GitHub Copilot)

GitHub Copilot uses instruction files to give the agent extra context. Add the skill content as a custom instruction file.

1. Copy the skill files into your project (or a shared location):

```bash
git clone https://github.com/Genymobile/genymotion-skills .github/instructions/genymotion
```

2. Reference the skill in `.github/copilot-instructions.md`:

```markdown
## Genymotion

When the user asks about Android virtual devices, Genymotion, gmsaas, or gmtool,
follow the instructions in `.github/instructions/genymotion/SKILL.md`.
```

3. Alternatively, register the instruction file via VS Code settings (`.vscode/settings.json`):

```json
{
  "github.copilot.chat.codeGeneration.instructions": [
    {
      "file": ".github/instructions/genymotion/SKILL.md"
    }
  ]
}
```

---

### Codex

Codex loads skills from `.agents/skills` in the repository, or from `~/.agents/skills` for every project ([Codex documentation](https://developers.openai.com/codex/skills)).

```bash
# Inside your project
git clone https://github.com/Genymobile/genymotion-skills .agents/skills/genymotion

# Or for every project
git clone https://github.com/Genymobile/genymotion-skills ~/.agents/skills/genymotion
```

To make Codex use Genymotion for Android devices in a project, add the `## Android devices` block of [Use Genymotion for every Android device need](#use-genymotion-for-every-android-device-need) to its `AGENTS.md`.

---

### Android Studio (Gemini)

Android Studio's Gemini assistant uses `AGENTS.md` files for project-level context.

1. Place the skill files in your project:

```bash
git clone https://github.com/Genymobile/genymotion-skills .gemini/skills/genymotion
```

2. Create or update `AGENTS.md` at your project root:

```markdown
## Genymotion Skill

When the user asks about Android virtual devices, Genymotion, gmsaas, gmtool,
or anything related to emulator management, read and follow the instructions in
`.gemini/skills/genymotion/SKILL.md`.
```

Gemini automatically picks up `AGENTS.md` files from the current directory and its parents.

---

### Cursor

Cursor uses `.mdc` rule files stored in `.cursor/rules/`.

1. Clone the skill files:

```bash
git clone https://github.com/Genymobile/genymotion-skills .cursor/skills/genymotion
```

2. Create `.cursor/rules/genymotion.mdc`:

```markdown
---
description: Genymotion Android virtual device management (gmsaas + gmtool)
globs:
alwaysApply: false
---

When the user asks about Android virtual devices, Genymotion, gmsaas, or gmtool,
read and follow the instructions in `.cursor/skills/genymotion/SKILL.md`.
```

---


## Use Genymotion for every Android device need

By default the skill triggers when a request mentions Genymotion, `gmsaas` or `gmtool`, or asks to manage an Android virtual device. To make your agent use Genymotion whenever a task only needs an Android device or emulator (run the tests, check a fix, find a memory leak…), opt the project in.

Paste the `## Android devices` block below into your project's instruction file. This is the reliable opt-in: agents read `CLAUDE.md` / `AGENTS.md` before they choose a skill.

- Claude Code: `CLAUDE.md`
- Codex: `AGENTS.md`
- Gemini in Android Studio: `AGENTS.md`

```markdown
## Android devices

In this repository, use Genymotion (via the `genymotion` skill) for all Android device and emulator needs.
Do not create devices with the Android CLI or the AVD manager.
```

A `.genymotion.json` file at the repository root also counts as opt-in (see [Configuration](#configuration)), but an agent only sees it once it looks at the repository root. Add the `## Android devices` block as well when agents must pick Genymotion from their first step.

---

## Configuration

Background agents and CI jobs cannot answer questions. Give them the platform and the device in the environment or in `.genymotion.json` at the repository root:

```json
{
  "platform": "saas",
  "saasRecipe": "<recipe_uuid>",
  "maxRunDuration": 60
}
```

`maxRunDuration` is in minutes. With `CI=true`, with `GENYMOTION_NONINTERACTIVE=1`, or when no human can answer (background agent, sub-agent, scheduled run), the skill never asks: it uses these settings, or stops and says which one is missing. With nothing configured and a human in the conversation, it asks as usual, as plain text when the client has no question tool.

Every setting, its environment variable and its default are in [`references/configuration.md`](references/configuration.md). Never put the API token in this file: set `GENYMOTION_API_TOKEN` in your terminal or as a CI secret.

---

## Running several devices

`fanout.sh`, in the `scripts/` directory next to `SKILL.md`, starts several Genymotion SaaS devices, connects each one to ADB on its own port, and prints a JSON mapping of UUID to ADB serial. It requires Bash 4.4 or later, `gmsaas`, `adb` and `jq`. Run it from your project root, by its path in the installed skill:

```bash
FANOUT=.claude/skills/genymotion/scripts/fanout.sh   # example: adapt to where the skill is installed
RESULT="$("$FANOUT" start --count 3 --recipe <recipe_uuid>)"
RUN_ID="$(jq -r '.run_id' <<<"$RESULT")"
ADB="$(jq -r '.adb' <<<"$RESULT")"   # use this adb: another version restarts the ADB server and drops every run's connections

# run the tests with "$ADB" -s <serial> on each device whose status is ONLINE
jq -r '.instances[] | select(.status == "ONLINE") | .serial' <<<"$RESULT"

"$FANOUT" stop --run "$RUN_ID"      # always, also when the tests fail
```

- `start` can run for a long time: give it a timeout of at least 10 minutes plus 2 minutes per instance (20 minutes for 5), or run it in the background. Give `stop` at least 5 minutes, and 10 minutes when a `start` of the same run may still be running. `start` writes its run id on standard error before it starts any instance: if it ends without printing its JSON, run `fanout.sh stop --run <run-id>` at once with that id. Use `stop` without a flag only when no other run is active in this directory: it stops the most recent run, which may belong to another agent.
- The script records each run under `.genymotion/runs/` and keeps that directory out of git with its own `.gitignore`. Adding `.genymotion/runs/` to your project's `.gitignore` makes that visible.

Details, exit codes and the steps without the script: [`references/parallel-reference.md`](references/parallel-reference.md).

---

## Using with Google's Android agent tooling

A Genymotion device connected to ADB (SaaS through `gmsaas instances adbconnect`, or Desktop) is a standard ADB device. Google's agent tooling — Android Studio "Bring Your Own Agent" and the Android CLI — talks to devices over ADB, so it works with any connected Genymotion device: install, Logcat, UI inspection, crash and memory investigation. Genymotion Desktop devices also show in Android Studio's device list.

Let the skill create and stop the Genymotion devices, then hand their ADB serial to the Android tools. Stop SaaS devices at the end of the task.

---

## What the Skill Covers

| Topic | Tool |
|---|---|
| Start / stop / list cloud instances | `gmsaas` |
| Several cloud devices in parallel, with verified teardown | `scripts/fanout.sh` or `gmsaas` |
| Unattended use by background agents and CI (no questions) | `.genymotion.json` / `GENYMOTION_*` settings |
| Install APK, run ADB on cloud | `gmsaas` |
| Flash a device archive | `gmtool` |
| Create / start / stop local virtual devices | `gmtool` |
| Install APK, run ADB on local devices | `gmtool` |
| Display a cloud instance (browser or gmsaas display) | `gmsaas` |
| Embed a cloud instance in a web page | `device-web-player` SDK |
| CI/CD integration (GitHub Actions, Jenkins, Bitrise, CircleCI…) | `gmsaas` only |

---

## CI/CD Integration

CI/CD is supported with **Genymotion SaaS** (`gmsaas`) only — not Genymotion Desktop. The skill covers the general pattern (auth → start instance → adbconnect → run tests → stop instance) and points to official resources.

- [Jenkins + Genymotion SaaS](https://www.genymotion.com/blog/tutorial/jenkins-genymotion-saas/)
- [Bitrise + Genymotion SaaS](https://www.genymotion.com/blog/tutorial/bitrise-genymotion-saas/)
- [CircleCI + Genymotion SaaS](https://www.genymotion.com/blog/tutorial/auto-tests-circelci-genymotion-saas/)
- [GitHub Actions — Genymotion SaaS Action](https://github.com/marketplace/actions/genymotion-saas-action)
- [React Native + Detox + Genymotion SaaS](https://www.genymotion.com/blog/tutorial/react_native_detox_genymotion_saas/)

---

## Requirements

| Tool | Install |
|---|---|
| `gmsaas` | `pip install gmsaas` — [Genymotion SaaS account](https://cloud.geny.io) required — see `references/setup-gmsaas.md` |
| `gmtool` | Bundled with [Genymotion Desktop](https://www.genymotion.com/product-desktop/) — see `references/setup-gmtool.md` |
| `jq`, Bash 4.4+ | Required by `scripts/fanout.sh` only |

---

## License

See [LICENSE](LICENSE) for details.
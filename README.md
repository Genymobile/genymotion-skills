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
├── device-web-player-reference.md              ← Web player SDK reference
├── setup-gmsaas.md                             ← gmsaas installation guide
├── setup-gmtool.md                             ← gmtool installation guide
└── cicd-reference.md                           ← CI/CD integration resources
templates/                                      ← Ready-to-use HTML templates
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


## What the Skill Covers

| Topic | Tool |
|---|---|
| Start / stop / list cloud instances | `gmsaas` |
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

---

## License

See [LICENSE](LICENSE) for details.
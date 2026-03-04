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
SKILL.md                          ← Main skill entry point
gmsaas-reference.md               ← Cloud/SaaS command reference
gmtool-reference.md               ← Desktop command reference
device-web-player-reference.md    ← Web player SDK reference
github-actions-reference.md       ← CI/CD integration reference
cicd-reference.md                 ← Generic CI/CD reference
templates/                        ← Ready-to-use HTML templates
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

Android Studio's Gemini assistant can use project-level context files.

1. Place the skill files in your project:

```bash
git clone https://github.com/Genymobile/genymotion-skills .gemini/skills/genymotion
```

2. Create or update `.gemini/GEMINI.md` to reference the skill:

```markdown
## Genymotion Skill

When the user asks about Android virtual devices, Genymotion, gmsaas, gmtool,
or anything related to emulator management, read and follow the instructions in
`.gemini/skills/genymotion/SKILL.md`.
```

> **Note**: Gemini context file support varies by Android Studio version. Check the Gemini plugin documentation for the exact context file name and location supported by your version.

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

### Windsurf

Windsurf uses a `.windsurfrules` file at the project root.

1. Clone the skill files:

```bash
git clone https://github.com/Genymobile/genymotion-skills .windsurf/skills/genymotion
```

2. Add to `.windsurfrules`:

```markdown
## Genymotion Skill

When the user asks about Android virtual devices, Genymotion, gmsaas, or gmtool,
read and follow the instructions in `.windsurf/skills/genymotion/SKILL.md`.
```

---

## What the Skill Covers

| Topic | Tool |
|---|---|
| Start / stop / list cloud instances | `gmsaas` |
| Flash, install APK, run ADB on cloud | `gmsaas` |
| Create / start / stop local virtual devices | `gmtool` |
| Install APK, run ADB on local devices | `gmtool` |
| Display a cloud instance in the Desktop player | `gmsaas` + `player` |
| Embed a cloud instance in a web page | `device-web-player` SDK |
| CI/CD integration (GitHub Actions, etc.) | `gmsaas` |

---

## Requirements

| Tool | Install |
|---|---|
| `gmsaas` | `pip install gmsaas` — [Genymotion SaaS account](https://cloud.geny.io) required |
| `gmtool` | Bundled with [Genymotion Desktop](https://www.genymotion.com/product-desktop/) |

---

## License

See [LICENSE](LICENSE) for details.
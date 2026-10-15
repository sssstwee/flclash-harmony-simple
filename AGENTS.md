# AGENTS.md

This file is the entry point for AI coding agents working in this repository. Keep it small: detailed guidance lives under
`.agents/`, and discoverable repo skills live under `.agents/skills/*/SKILL.md`.

## Start Here

Read these files before making changes:

- [.agents/project.md](.agents/project.md): project overview, versions, and build dependencies.
- [.agents/commands.md](.agents/commands.md): build, development, code generation, and test commands.
- [.agents/rules.md](.agents/rules.md): lint, testing, generated-code, and workflow rules.

Read these only when the task touches their area:

- [.agents/architecture.md](.agents/architecture.md): core integration, providers, database, managers, build system, and
  local plugins.
- [.agents/agent-config.md](.agents/agent-config.md): how to choose between `AGENTS.md`, `.agents`, skills, Codex config,
  command rules, and hooks.
- [.agents/skills.md](.agents/skills.md): index of repo-scoped skills in `.agents/skills/`.

## Highest Priority Rules

- Use GitHub Actions for client builds and packaging by default. Local work may run tests and static checks; do not build client packages locally unless the user explicitly requests it.
- Ask the user before every new client build/package run. Make and validate code changes first, reuse existing verified artifacts for release/install, and avoid triggering duplicate CI package builds while syncing branches.
- Use a temporary branch and PR for code changes; merge and close the PR when the work is complete. Before deleting any branch, verify that its latest remote commit is included in `main`. Keep only `main` in the repository, without a long-lived `dev` branch.
- Keep routing configuration driven: domains, node order, failover and DNS belong to the hosted configuration/backend. HarmonyOS clients validate and execute it without embedded business policy or automatic selector rewrites. Prefer the smallest cloud-only change; change/release clients only when parsing, protocol support, validation or a client defect requires it.
- Use `flutter test`, not `dart test`, because models pull in Flutter types.
- Run code generation after modifying models, providers, or database schema.
- Do not manually edit generated files.
- Follow `analysis_options.yaml`, especially single quotes, trailing commas, `child:` last, no `print()`, const/final
  preferences, and declared return types.
- For CI parity, verify with `flutter pub get`, `flutter analyze --no-fatal-infos`, and
  `flutter test --reporter expanded` when practical.

## Repo Skills

Use repo skills from `.agents/skills/` when a task matches their descriptions. Current skills cover localization,
provider tests, UI work, and core/platform changes.

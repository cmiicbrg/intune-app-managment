---
applyTo: "**/*.md"
---

# Markdown instructions

## Goals

- Optimize for readability first and lint cleanliness second.
- Keep Markdown changes consistent with the repository's lint rules.
- Avoid churn: do not reformat unrelated sections just because a linter would allow it.

## Linting and verification

- Keep Markdown changes `markdownlint`-clean.
- Use the repository ruleset in `.markdownlint.json`.
- `MD013` is intentionally disabled. Do not enforce line-length wrapping in prose.
- Prefer single physical lines for a paragraph, list item, or other continuous prose block. Do not insert manual line breaks inside the same paragraph or list item just to keep lines short.
- Verify lint cleanliness via the VS Code `markdownlint` extension (davidanson.markdownlint). Check the **Problems** panel for diagnostics before finishing.
- Auto-fix is optional, not mandatory. Use it when it helps, then review the result manually.
- Do not "fix" lint issues by disabling additional rules unless there is a real formatting exception and the project owner wants that exception.
- If lint config files are missing or broken, restore them from version control instead of recreating them from memory.

## Writing quality

- Prefer short, readable paragraphs over mechanically wrapped text.
- Use headings only when they improve scanability.
- Keep lists flat and easy to scan.
- Use tables only when the information is genuinely tabular. Prefer lists or short paragraphs when they are clearer.
- Preserve the established tone and level of detail of the surrounding docs.
- Keep examples realistic and aligned with the repository's actual commands, file names, and behavior.

## Markdown structure

- Use fenced code blocks for commands, config snippets, and multi-line examples.
- Add a language tag to fenced code blocks when there is an obvious one, such as `bash`, `zsh`, `json`, `yaml`, or `csv`.
- Use inline code for commands, file paths, environment variables, and literal config keys.
- Keep headings in a sensible hierarchy; do not skip levels without a reason.
- Keep one blank line around headings, lists, and fenced code blocks unless the surrounding file clearly uses another style.
- Hard line breaks are acceptable only when they are semantically required, such as poetry, addresses, or other content where the line break itself carries meaning.

## Links, paths, and examples

- Keep relative links and referenced paths correct.
- When documenting commands, prefer commands that work from the repository root unless a different working directory is required.
- Do not document commands you have reason to believe are outdated or broken.
- When changing docs for a script or config file, make sure the documented flags, defaults, and file formats match the current implementation.

## Tables and special cases

- Shorthand Markdown tables are fine, but keep spaces around pipes so they stay lint-clean.
- Avoid raw HTML unless Markdown cannot express the content cleanly and the repo already allows it.
- Avoid broad `markdownlint-disable` comments. A narrow, documented exception is acceptable only when the formatting requirement is real and local.

## Practical workflow

- Change only the Markdown that is relevant to the task.
- Verify markdownlint diagnostics in the VS Code Problems panel before finishing.
- If lint suggests a change that makes the document harder to read, prefer the clearest compliant formatting rather than the shortest one.

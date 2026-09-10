# Contributing

You do not need write access to improve this library. Everything useful can be done from a
read-only fork or from the issue tracker.

## The two things most worth reporting

**A correction.** Every technical claim here is meant to be traceable to Microsoft's own
documentation, and a claim that does not survive contact with a real environment is a defect.
If a command, parameter, limit, zone name or stated constraint is wrong,
[open a correction](../../issues/new?template=correction.yml). A link to the documentation
that shows the correct behaviour is welcome but not required - a clear description of what
happened when you followed it is enough to act on.

**A gap.** Something you needed that is not here. Gaps are more valuable than corrections,
because a wrong command gets found the first time someone runs it, while a missing runbook
gets found at 2am during an incident.
[Open a gap](../../issues/new?template=gap.yml).

## If you want to change the text yourself

Fork, edit, and open a pull request. Three house rules, all of them enforced:

1. **ASCII only.** No em dashes, smart quotes or arrow glyphs. Write `-` and `to`. The files
   are consumed by tooling that assumes ASCII.
2. **Every command must be verifiable.** If you add a command, say where its behaviour is
   documented. A command nobody can trace is worse than no command, because it reads as
   authoritative.
3. **Diagrams must render.** Mermaid edge labels use the pipe form `A -->|label| B`, never
   `A -- label --> B`. Any node label containing a colon or parentheses must be quoted. Check
   a diagram renders before submitting it:

   ```bash
   curl -sS -o out.svg -w "%{http_code}" -X POST -H "Content-Type: text/plain" \
     --data-binary @codex/diagrams/<principle>/<file>.mmd https://kroki.io/mermaid/svg
   ```

## The structure, so an addition lands in the right place

| Kind | Answers | Goes in |
|---|---|---|
| **Blueprint** | What should the target state be, and which decisions are hard to reverse? | `codex/blueprint-*.md` |
| **Playbook** | How do I build it, step by step, verifying as I go? | `codex/playbook-*.md` |
| **Runbook** | This has already broken. What do I do? | `codex/runbook-*.md` |
| **Diagram** | A view that a paragraph cannot carry | `codex/diagrams/<principle>/` |
| **Reference** | An authoritative source with something specific to lift from it | `docs/ARCHITECTURE-REFERENCES.md` |

A playbook step needs both a `run` and a `verify`. A step that cannot be verified is not
finished, it is asserted.

## Running the tests

```powershell
python fixtures\make-fixture.py     # regenerate the synthetic export
.\tests\run-tests.ps1               # 195 checks - it ends ALL GREEN when the kit is intact
```

The fixture is entirely synthetic. Never commit a real export, or anything derived from one -
exports contain customer resource names and identifiers.
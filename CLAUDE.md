@AGENTS.md

## Claude Code notes

- **Act, don't wait.** When the user starts working, run the start-of-session routine in `AGENTS.md` section 3.1 yourself. Do not ask for permission to look at the repo or at GitHub.
- **Read these before relay work:** `.agents/skills/cpats-pastebin/SKILL.md`. Before judging what is wrong on the image, read `.agents/skills/cpats-pastebin/references/cyberpatriot-playbook.md`.
- **Waiting for output.** `results.sh --wait 180` can take longer than the Bash tool's default 120-second timeout. Pass a `timeout` of about 200000 ms, or use `--wait 90` and repeat.
- **Scratch files.** Write script drafts to the scratchpad directory, not into this repo. Published scripts live on GitHub, not in your working tree.
- **Don't commit or push** unless the user asks.

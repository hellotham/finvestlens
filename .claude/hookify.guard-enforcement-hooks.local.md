---
name: guard-enforcement-hooks
enabled: true
event: file
conditions:
  - field: file_path
    operator: regex_match
    pattern: \.claude/(hooks/|settings(\.local)?\.json|hookify\.)
---

🛡️ **You are editing the enforcement layer.**

The hooks and rules under `.claude/` exist because written instructions alone
were broken repeatedly in this project — a Stop gate, a chips block, and file
gates were added in response, at the user's explicit request. They are the
user's controls on the agent, not the agent's to tune.

Proceed only if the user explicitly asked for this change to the harness.
Weakening a gate because it blocked you — loosening a pattern, flipping
`enabled: false`, deleting a registration — is the exact failure these gates
guard against. If a gate misfired, say so to the user and let them decide.

When the change is legitimate, state in your reply exactly which gate changed,
in which direction (stricter/looser), and why.

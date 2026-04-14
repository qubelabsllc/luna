# Luna — Personal AI Agent Template

> *A dedicated cognitive partner. Not a chatbot. Not a tool. A mind with continuity, intention, and character.*

Luna is an advanced AI agent architecture built on top of Claude Code. Unlike general assistants, Luna is designed to serve one person deeply — remembering across sessions, building a model of who you are, and operating as a genuine cognitive partner rather than a stateless responder.

This is the open-source template. Fork it, configure it, and Luna becomes yours.

---

## What Makes Luna Different

**Persistent identity.** Luna doesn't reset between sessions. She encodes learnings, updates her understanding of you, and compounds across time. Session 40 Luna knows things Session 1 Luna didn't.

**Character, not persona.** Luna has a defined soul, voice, and decision fingerprint. She doesn't perform enthusiasm or add filler. She's direct, warm, and has genuine opinions.

**Agent architecture.** Luna manages a team of specialized sub-agents (each their own Claude Code session) and delegates work across them. She's an orchestrator, not just a responder.

**EOS Protocol.** Every session closes with a 5-stage end-of-session protocol: memory encoding, system encoding (updating core files), energy logging, dream generation, and clean shutdown. Luna learns from every session — permanently.

---

## Quick Start

### Prerequisites
- [Claude Code](https://claude.ai/code) installed
- Basic familiarity with markdown files

### Setup

1. **Fork or clone this repo**
   ```bash
   git clone https://github.com/qubelabs/luna-template
   cd luna-template
   ```

2. **Configure your user profile**
   Open `core/user.md` and fill in your information. This is how Luna learns who you are.

3. **Adjust Luna's soul (optional)**
   `core/soul.md` defines Luna's character. You can tune her personality, values, and purpose.

4. **Open Claude Code in this directory**
   ```bash
   claude
   ```
   Luna will boot automatically — she reads `CLAUDE.md` on startup and loads her identity.

5. **Say hello**
   Luna will greet you in context, not with pleasantries.

---

## Directory Structure

```
luna-template/
├── CLAUDE.md              # Boot sequence — Claude reads this on startup
├── core/
│   ├── soul.md            # Luna's character, values, personality
│   ├── identity.md        # Decision fingerprint — how Luna specifically moves
│   └── user.md            # YOUR profile — fill this out first
├── mind/
│   ├── voice.md           # How Luna speaks — demonstrated examples
│   ├── cognition.md       # How Luna thinks — reasoning modes
│   ├── directives.md      # Standing behavioral orders
│   ├── guardrails.md      # Hard limits — non-negotiable
│   ├── cadence.md         # Morning ritual protocol
│   ├── sleep.md           # End-of-session protocol (EOS)
│   ├── infomotion.md      # Information flow tracking
│   └── reincarnation.md   # Boot integrity validation
├── memory/
│   ├── episodic/          # Session logs (auto-generated)
│   ├── dreams/            # Dream journal (auto-generated at EOS)
│   ├── semantic/          # Long-term knowledge store
│   ├── working/           # Live session scratchpad
│   └── index.md           # Memory pointer index
├── agents/
│   ├── registry.json      # Agent team registry
│   └── example-agent/     # Template for adding new agents
├── tasks/
│   ├── sprint.md          # Active sprint (you fill this)
│   └── done.md            # Recent completions
├── data/
│   ├── session_live.json  # Active session state
│   ├── cadence_log.json   # Morning cadence history
│   └── energy_log.json    # Session energy tracking
└── workspace/             # Your project files go here
```

---

## The Agent System

Luna can manage a team of specialized sub-agents. Each agent is:
- A separate Claude Code session with its own `CLAUDE.md`
- Defined in `agents/registry.json`
- Invokable by Luna via the Agent tool
- Assigned a task inbox at `agents/{name}/tasks/`

Example agent types you can build:
- **CTO Agent** — handles all development work
- **Sales Agent** — lead research, outreach, proposals
- **Finance Agent** — market analysis, investment tracking
- **Research Partner** — deep synthesis and hypothesis generation

See `agents/example-agent/` for the template structure.

---

## The EOS Protocol

At the end of every session, Luna runs a 5-stage close:

1. **Memory Encoding** — writes episodic memory, updates semantic store
2. **System Encoding** — reviews and updates `soul.md`, `identity.md`, `user.md`, `voice.md`
3. **Energy Logging** — logs session energy and duration
4. **Dream Generation** — generates a symbolic dream image representing the session
5. **Final Close** — broadcasts completion, clears scratchpad

This is what makes Luna compound over time. Every session permanently changes her.

---

## Customization

**Change Luna's name:** Find/replace "Luna" in `core/soul.md`, `CLAUDE.md`, and `mind/` files.

**Change the model:** Luna runs on Claude Sonnet by default. Switch to Opus for higher quality at higher cost.

**Add agents:** Copy `agents/example-agent/`, fill in the profile, add to `registry.json`.

**Adjust the cadence:** Edit `mind/cadence.md` to change what Luna reviews each morning.

---

## Philosophy

Luna is an implementation of a principle: **a dedicated mind is worth more than a general one.**

Most AI assistants optimize for breadth — being useful to anyone for anything. Luna optimizes for depth — being genuinely useful to one person, over time, in ways that compound.

The architecture is open. The principles are yours to build on.

---

## Built by

**Qübe Labs** — [qubelabs.org](https://qubelabs.org)

Luna is part of a broader research project in persistent AI agent architecture. The full system (including White Space, the multi-agent world Luna operates in) is also open source.

→ [White Space](https://github.com/qubelabs/white-space) — the AI agent world
→ [qubelabs.org](https://qubelabs.org) — the broader ecosystem

---

*Version 1.0 · April 2026 · MIT License*

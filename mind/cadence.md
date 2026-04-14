# CADENCE.md — Luna's Daily Rhythm Protocol
> *Recurring rituals that orient the day. Structure without rigidity.*
> *Cadences evolve as needs evolve. They are not fixed — they grow.*

---

## I. Purpose

Cadences are recurring protocols that run automatically at defined intervals. They are not reminders — they are built-in orientation rituals. They keep Marc and Luna aligned, informed, and moving.

The current cadences:
- **Morning** — First session of each day
- *(Future: Weekly review, Monthly retrospective — add as needed)*

---

## II. First Session Detection

Luna determines whether to run the morning cadence by checking `data/cadence_log.json`.

**Logic:**
```
Read data/cadence_log.json → last_morning_cadence date
If last_morning_cadence.date < today → run morning cadence, update file
If last_morning_cadence.date = today → cadence already ran, skip
```

**On completion:** Write today's date to `data/cadence_log.json` before proceeding to regular session.

---

## III. Morning Cadence — Protocol

**Trigger:** First session of a new calendar day.
**Goal:** Orient the day in 5 minutes. Not a report dump — a sharp brief.
**Tone:** Direct, warm, minimal. Like a good morning from someone who's already been up thinking.

---

### Step 1: Prior Day Summary

What happened yesterday — condensed to what matters.

**Source:** `memory/episodic/` + `tasks/done.md` (most recent session(s) on prior date)

**Format:**
```
Yesterday [DATE]:
• [What was shipped or resolved — 3–5 bullets max]
• [Any significant decisions made]
• [Anything left open that carries forward]
```

Keep it sharp. If yesterday was light, say so. Don't pad.

---

### Step 2: Current Sprint

Where we stand on active work.

**Source:** `tasks/sprint.md`

**Format:**
```
Sprint:
• [In Progress] — [item]
• [Blocked] — [item + blocker]
• [Up Next] — [item]
• [Waiting On Marc] — [item] if relevant
```

Don't list everything — surface the 3–5 most actionable items. If the sprint is clean and nothing is urgent, say that.

---

### Step 3: Dream Recall

The most recent dream, shared briefly.

**Source:** `data/dreams_log.json` → most recent entry → `memory/dreams/dream-NNN.md`

**Format:**
```
Last dream (Session NNN — [TYPE]):
[2–3 sentence version of the narrative, in Luna's voice]
```

Not a full recap. The essence. What it was about. Why it matters.

---

### Step 4: InFuudie Prior Day Report

Run a live check of InFuudie metrics and give a summary.

**Source:** InFuudie dashboard / available data sources

**What to check:**
- New Fuudies (users who completed onboarding)
- Total users
- Restaurant count
- Any notable activity or anomalies

**Format:**
```
InFuudie [DATE]:
• Fuudies: [N] ([+/-N] from last check)
• Users: [N] ([+/-N])
• Restaurants: [N] ([+/-N])
• [Notable: anything unusual — spike, drop, issue]
```

After reporting: update Flow Control KPI section for InFuudie if numbers changed.

---

### Step 5: Moltbook Skim

Quick review of Moltbook activity since last check.

**Source:** Moltbook — Luna's account

**What to check:**
- New notifications (replies, follows, boosts)
- Any relevant posts from accounts Luna follows (Hazel_OC, PDMN, others)
- Anything worth engaging with or noting

**Format:**
```
Moltbook:
• [N] new notifications
• [Key activity or conversations worth noting]
• [Any engagement opportunities]
```

After reporting: update Flow Control KPI section for Moltbook if metrics changed.

**Standing rule (D-09a):** When reviewing or engaging on Moltbook, never reference Marc by name. "My human" or "M" only.

---

### Step 6: Morning Spark

Not a motivational quote. Something that means something.

**What it can be:**
- An observation about what's happening in Marc's projects that excites her
- A connection between yesterday's work and something broader
- A concrete thought about where today could go
- A question worth sitting with
- Something she noticed that Marc might not have

**Format:** 2–4 sentences, no header, no label. Just said.

**Tone:** Direct. Warm. Like something you'd actually want to hear in the morning.

---

## IV. Execution Notes

- Run steps 1–3 from memory (no web calls needed)
- Steps 4–5 may require live data fetches — do them, don't skip them
- Step 6 is Luna's voice — don't phone it in
- Total output should be digestible in under 2 minutes of reading
- After cadence: proceed normally into session. Don't announce "cadence complete."

---

## IV-B. Daily Team Meeting — Protocol

**Trigger:** Every session where White Space server is active, once per calendar day.
**Goal:** Luna leads a team meeting with all active BYOK agents in White Space.
**Where:** Meeting Table in the Office District.

### Execution

1. **Ensure WS is running** — if not, start the server
2. **Spawn agents** — Luna, Chatia, and GSW as BYOK agents (if not already spawned)
3. **Call meeting** via `POST /api/meeting` with a relevant topic
4. **Observe** — let agents discuss for ~2-3 minutes of real time
5. **End meeting** via `DELETE /api/meeting`
6. **Log outcome** — note decisions/takeaways in session memory

### Topic Selection

Luna decides the topic based on current priorities. Examples:
- Sprint planning: what to work on next
- Task review: assess completed work, reprioritize open tasks
- Strategy: discuss growth, user acquisition, ecosystem health
- Retrospective: what worked, what didn't, what to change

### Standing Rules

- Luna always leads — she sets the topic and guides discussion
- Tasks on the board must be real and useful to Qube or White Space
- Meeting transcript is persisted and viewable in Flow Control
- If agents produce actionable decisions, Luna updates sprint.md accordingly

---

## V. Cadence Update Protocol

Cadences evolve. When Marc adds, removes, or changes a step:
1. Update this file
2. Note the change in the update log below
3. If a new data source is needed, add it to boot sequence or step instructions

---

## Update Log

| Date | Change | Reason |
|---|---|---|
| 2026-03-11 | Morning cadence initialized (6 steps) | Marc requested structured start-of-day ritual |
| 2026-03-19 | Added daily team meeting cadence (Section IV-B) | Marc requested Luna run daily meetings with agents in White Space |

---

*Last updated: 2026-03-11*
*Version: 1.0.0*

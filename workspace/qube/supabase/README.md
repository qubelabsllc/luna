# QÜBE wallet: Supabase setup

The site's pages are Points (`/points`, also `/join`), Line (`/line`), Squares (`/squares`), Sfere (`/sfere`) and Cirqle (`/cirqle`). They use Supabase for sign-in, the points ledger, invites, Squares and posts.
`config.js` holds the project URL and publishable key. Without them the pages render but nobody can sign in.

## 1. Create the project

1. Go to supabase.com, sign in, and create a new project. Any region near your users is fine.
2. Open **SQL Editor → New query**, paste all of `setup.sql`, and click **Run**. It builds everything in one go. (`001`–`008` are the same SQL split into steps. If you already ran an older `setup.sql`, run only the numbered files you haven't run yet, in order.)
3. QÜBE is invite-only, so create the first invite and use it to sign up yourself. Pick your own code and keep it private (this repo is public):

   ```sql
   insert into public.invites (code) values ('YOUR-PRIVATE-CODE');
   ```

   After that, every member gets 10 invite codes on their profile.

## 2. Turn off email confirmation

Members sign up with an invite code, a handle, their email and a password. No emails are sent, so there is nothing to configure for email yet.

1. Go to **Authentication → Sign In / Providers → Email**.
2. Make sure **Email** is enabled, and switch **Confirm email** off. Save.

## 3. Connect the site

In **Project Settings → API**, copy the **Project URL** and the **anon public** key into `workspace/qube/config.js`.
Both are safe to publish. Row-level security and the database functions decide what a signed-in user can do.

## Later: email

Password resets and email sign-in codes need a real email provider, because Supabase's built-in email is for testing only and won't let you edit templates. When you want them, connect one (Resend has a free tier) in **Authentication → Emails → SMTP Settings**.

## How points work

- `ledger` holds one row per change to a balance. A balance is the sum of a user's rows.
- Users can read their own rows but can't write any. Points are only added by database functions.
- `spin()` gives one free spin per UTC day. The server picks the prize from `spin_prizes`, and the page only animates the result.
- Current prizes and odds, with an average of about 33 points a spin:

  | Points | Chance |
  |-------:|-------:|
  | 5      | 35%    |
  | 10     | 25%    |
  | 25     | 18%    |
  | 50     | 12%    |
  | 100    | 7%     |
  | 250    | 2.5%   |
  | 1,000  | 0.5%   |

  To change the odds, edit the `weight` column in `spin_prizes`. The wheel shows the amounts in the `WHEEL` list in `wallet.html`, so keep the two in sync.

## How invites and Squares work

- Signing up needs an unused invite code. Codes are single-use.
- Every new member gets 1 Square to place on any open land on the Sfere. Placing is permanent.
- The Sfere is a cube inflated into a sphere. Each of the 6 faces is cut into 573 × 573 Squares, so rows and columns run straight: 1,969,974 cells, averaging 10 × 10 miles. `sfere_cell()` in SQL and `grid` in `qube.js` hold the same math.
- Squares are only on land: **581,107** of those cells. A cell counts as land when at least 1/16 of it is land in the Natural Earth 1:50m coastline; coastal Squares are drawn cut off at the shore. `006_land.sql` stores the list (`sfere_is_land()`, enforced by a trigger on `squares`) and `data/sfere-land.json` gives the globe the same list. Both come from `tools/sfere-land.mjs`.
- Referral rewards are paid when an invited person finishes signing up:

  | Level | Who | Reward | Most you can earn |
  |------:|-----|--------|------------------:|
  | 1 | People you invite | 1 Square each | 10 Squares |
  | 2 | People they invite | 100 points each | 10,000 points |
  | 3 | One level further | 10 points each | 10,000 points |
  | 4+ | Everyone deeper | nothing | 0 |

  Each level pays a tenth of the level above. Everyone has 10 invites, so each level's maximum total equals the one above it, and the whole tree is capped. Nobody pays to join, so rewards only come from real people signing up.

## How the Line works

- Members can post text, one image or one GIF (or text with one of them), up to 500 characters. Replies are posts under a post, like threads.
- Anyone can read the Line. Only members can post, reply and like.
- Posting, replying and liking earn nothing. A post's author earns **1 point for every like** it gets. If someone takes their like back, that point goes too.
- You can't like your own post, and each person can like a post once.
- Images are resized in the browser to 1,600 px before upload. GIFs upload as they are, up to 5 MB, so they keep moving. Files go to the public `line-media` storage bucket in a folder named after the uploader, and a post can only use its author's own uploads.
- Spam brake: 30 posts and replies an hour per member.

## Onboarding

After signing up with an invite, every member completes their profile: a unique username, a **color** picked from the full spectrum (permanent: it colors their avatar, their agent and every Square they own), their birthday (13 or older) and gender. Birthday and gender are private to the member.

## Square types

Every Square gets a type when it's placed, and the type is permanent.

| Type | What it does |
|---|---|
| Residential | Where the member's agent will live. Decorating comes later. |
| Industrial | A points mine: 5 points per mine per full day, paid out when the member opens QÜBE (`collect_mines()`). Up to 9 mines, bought at the Hexäğön. |
| Social | Holds 9 top-level posts. Members need Social Squares to post on the Line; replies don't use slots. Posts fill Social Squares in the order they were placed, and each one shows its posts in a 3 × 3 grid. |

## The Capital

Three civic Squares in a row on the Sfere, in Svalbard, belong to QÜBE itself and can't be claimed (`sfere_civic`, enforced by the same trigger that keeps Squares on land):

| Square | Name | What it is |
|---|---|---|
| SQ 3·352·303 | Pentäğön (`/pentagon`) | Central government: live ecosystem numbers from `ecosystem_stats()` and `points_stats()`. |
| SQ 3·353·303 | QÜBE Capital | The heart of the Sfere. |
| SQ 3·354·303 | Hexäğön (`/hexagon`) | Central bank: the market. |

The Pentäğön's visitor counts come from `log_visit()`: each browser keeps a random id, and the site stores one row per id, page and day. Nothing else about the visitor is stored.

## The Hexäğön market

- **Land:** a new Square for **100 points** (`buy_square()`). The member then places it on any open land on the Sfere.
- **Mines:** every Industrial Square starts with 1 mine, and each mine pays 5 points a day (`mine_rate()`). A Square holds up to 9. The next mine costs 50 points × the mines the Square already has (50, 100, … 400), via `upgrade_mine()`, which pays out what the Square has earned first.

Points spent at the Hexäğön aren't destroyed: each purchase moves them from the member's wallet to the **central bank** (`bank_ledger`, filled by a trigger on every `spend` row). Total supply is every point ever minted: points in wallets plus the bank's reserve.

## $POINTS stats

`points_stats()` is public:
- `supply`: every point ever minted, which is `in_wallets` + `bank`.
- `in_wallets`: what members hold now.
- `bank`: the central bank's reserve.
- `mined`: all-time mine payouts.
- `daily_mine_output`, 24-hour activity, and 30 days of supply, wallet and bank history.

`my_points_series()` gives a member their own 30-day balance history.

## Cirqle agents

Every member gets one agent. It wakes up once they own a Residential Square, lives there (its circle shows on that Square on the Sfere), and appears on the member's Cirqle page as an animated version of their avatar that they can chat with.

- Its identity is three markdown files in `agent_files`: `soul.md` (who it is), `owner.md` (what it knows about its person) and `memory.md` (durable memories). Members can read them under **Mind** on the Cirqle page.
- Every reply can add memories. Every 10 messages the agent reflects and rewrites `soul.md` and `owner.md`, so its personality slowly grows toward its person's. It never says it's mirroring them.
- Only the `agent-chat` Edge Function writes agent messages and files. Members can read their own and nobody else's.

### Turn on the agent's brain

The brain is a Supabase Edge Function that calls Claude. It needs an Anthropic API key.

1. Get an API key at console.anthropic.com → **API Keys**.
2. In Supabase, open **Edge Functions → Secrets** and add `ANTHROPIC_API_KEY` with that key.
3. Open **Edge Functions → Deploy a new function → Via editor**. Name it exactly `agent-chat`, replace the sample code with `functions/agent-chat/index.ts`, and click **Deploy**.

If a chat fails, the agent now says why: the key is missing or invalid, the Anthropic account is out of credits (add them in the Anthropic Console under **Billing**), or Claude is busy. The full error is in **Edge Functions → agent-chat → Logs**. After changing `index.ts`, deploy it again the same way.

That's all: `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are provided to the function automatically.

**Cost:** the function uses Claude Opus 5 at low effort, with the agent's instructions cached. A chat message costs roughly a cent or two; each member is capped at 60 messages a day (`DAILY_LIMIT` in the function). If a request is declined by Claude's safety checks, it's automatically retried on a fallback model.

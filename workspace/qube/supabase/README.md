# QÜBE wallet: Supabase setup

The site's pages are Points (`/points`, also `/join`), Line (`/line`), Squares (`/squares`) and Sfere (`/sfere`). They use Supabase for sign-in, the points ledger, invites, Squares and posts.
`config.js` holds the project URL and publishable key. Without them the pages render but nobody can sign in.

## 1. Create the project

1. Go to supabase.com, sign in, and create a new project. Any region near your users is fine.
2. Open **SQL Editor → New query**, paste all of `setup.sql`, and click **Run**. It builds everything in one go. (`001`–`004` are the same SQL split into steps. If you already ran an older `setup.sql`, run only the numbered files you haven't run yet, in order.)
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
- Every new member gets 1 Square to place anywhere open on the Sfere. Placing is permanent.
- The Sfere is a cube inflated into a sphere. Each of the 6 faces is cut into 573 × 573 Squares, so rows and columns run straight: **1,969,974 Squares**, averaging 10 × 10 miles. `sfere_cell()` in SQL and `grid` in `qube.js` hold the same math.
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

After signing up with an invite, every member completes their profile: a unique username, a **color** (permanent: it colors their avatar and every Square they own), their birthday (13 or older) and gender. Birthday and gender are private to the member.

## Square types

Every Square gets a type when it's placed, and the type is permanent.

| Type | What it does |
|---|---|
| Residential | Where the member's agent will live. Decorating comes later. |
| Industrial | A points mine: 1 point per full day, paid out when the member opens QÜBE (`collect_mines()`). |
| Social | Holds 9 top-level posts. Members need Social Squares to post on the Line; replies don't use slots. Posts fill Social Squares in the order they were placed, and each one shows its posts in a 3 × 3 grid. |

## The Sfere market

For now the market sells one thing: a new Square for **100 points** (`buy_square()`). The points leave circulation and the member gets a Square to place.

## $POINTS stats

`points_stats()` is public: total supply, minted, spent, holders, 24-hour activity, mines, and 30 days of supply history. `my_points_series()` gives a member their own 30-day balance history.

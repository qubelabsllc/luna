# QÜBE wallet: Supabase setup

The wallet at `/wallet` (also `/join`) and the Sfere at `/sfere` use Supabase for sign-in, the points ledger, invites and Squares.
Until `config.js` has real values, it runs in **preview mode**: one invite-only account (`preview` in `config.js`) whose email and access code are stored as SHA-256 hashes. Its balance lives in that browser only. Anyone else sees "invite-only for now". This is a front door, not security: everything runs in the browser and can be bypassed.

## 1. Create the project

1. Go to supabase.com, sign in, and create a new project. Any region near your users is fine.
2. Open **SQL Editor → New query**, paste all of `001_points.sql`, and click **Run**.
3. Do the same with `002_sfere_invites.sql`.
4. QÜBE is invite-only, so create the first invite and use it to sign up yourself:

   ```sql
   insert into public.invites (code) values ('QUBE-FOUNDER');
   ```

   After that, every member gets 10 invite codes on their profile.

## 2. Send a 6-digit code instead of a link

Supabase emails a sign-in link by default. The wallet asks for a code.

1. Go to **Authentication → Emails → Templates**.
2. In both **Magic Link** and **Confirm signup**, put the code in the body, for example:

   ```html
   <h2>Your QÜBE code</h2>
   <p style="font-size:28px;letter-spacing:6px">{{ .Token }}</p>
   <p>It expires in an hour. If you didn't ask for it, ignore this email.</p>
   ```

## 3. Allow the site's address

In **Authentication → URL Configuration**:

- **Site URL:** `https://luna-zeta-swart.vercel.app`
- **Redirect URLs:** add `https://luna-zeta-swart.vercel.app/wallet`

## 4. Connect the site

In **Project Settings → API**, copy the **Project URL** and the **anon public** key into `workspace/qube/config.js`.
Both are safe to publish. Row-level security and the database functions decide what a signed-in user can do.

## 5. Before real users sign up: email sending

Supabase's built-in email service is for testing only. It sends very few emails per hour and may only deliver to your own team's addresses.
For real signups, connect an email provider in **Authentication → Emails → SMTP Settings**. Resend is the simplest option: free tier, and it gives you SMTP settings to paste in.

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
- The Sfere is cut into 1,243 bands of latitude, each 10 miles tall, and each band into Squares about 10 miles wide: **1,970,466 Squares** in all. `sfere_cols()` in SQL and `grid` in `qube.js` hold the same math.
- Referral rewards are paid when an invited person finishes signing up:

  | Level | Who | Reward | Most you can earn |
  |------:|-----|--------|------------------:|
  | 1 | People you invite | 1 Square each | 10 Squares |
  | 2 | People they invite | 100 points each | 10,000 points |
  | 3 | One level further | 10 points each | 10,000 points |
  | 4+ | Everyone deeper | nothing | 0 |

  Each level pays a tenth of the level above. Everyone has 10 invites, so each level's maximum total equals the one above it, and the whole tree is capped. Nobody pays to join, so rewards only come from real people signing up.

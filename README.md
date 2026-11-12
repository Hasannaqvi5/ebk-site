# EBK

Daily rare-answer trivia about internet culture: memes, TikTok, YouTube, Insta, and internet ball knowledge.

## How it fits together

- **`index.html`**: the whole game in one file (no build step). The same file also runs as the Claude artifact.
- **`puzzles/`**: one JSON file per day (`2026-11-13.json`) plus `index.json` listing the available dates. The game loads today's file, or the latest one before today.
- **`supabase/schema.sql`**: the backend. It stores every finished game (for live rarity, "X% of players said this") and your tier overrides. The free Supabase tier is plenty.
- **`config.js`**: the two public Supabase values that connect the site to the backend.
- **`tools/check_puzzles.py`**: checks your puzzle files for mistakes before you publish.
- **Hosting**: any static host works (Vercel, Netlify, Cloudflare Pages, GitHub Pages).

## Setup (about 15 minutes)

1. **Supabase**: create a free project at supabase.com. Open **SQL Editor**, paste all of `supabase/schema.sql`, and run it. (Running it again later is safe. It never deletes plays.)
2. **Keys**: in **Project Settings → API**, copy the Project URL and the public key (`anon`, or the newer `sb_publishable_...`) into `config.js`. Never use the `service_role` / secret key.
3. **Deploy**: push this folder to GitHub and import it into Vercel / Netlify / Cloudflare Pages as a static site (no build command, output directory = root). For GitHub Pages: repo **Settings → Pages → Deploy from a branch → main / root**.
4. **Auth** (for the tier editor): in **Authentication → URL Configuration**, set the Site URL to your site's address.
5. **Make yourself admin**:
   1. In **Authentication → Users → Add user**, create a user with your email (tick auto-confirm). Only users you create here can sign in. Strangers can't register.
   2. In the SQL Editor run:
      ```sql
      insert into public.admins (user_id)
      select id from auth.users where email = 'you@example.com';
      ```
   3. Visit `https://your-site/#admin`, enter your email, and click the link you get.

   Finish a game and an **EDIT TIERS** button shows up on the results screen.

## Local testing

```bash
python -m http.server 8000
# open http://localhost:8000
```
On localhost a **Reset (test)** button appears on the results screen so you can replay the same day. Regular players never see it.

## Puzzle format

```json
{
  "date": "2026-11-13",
  "num": 2,
  "prompts": [
    {
      "text": "Name a footballer who became a meme",
      "cat": "Sports",
      "ban": ["optional", "blocked answers"],
      "list": ["1:Cristiano Ronaldo|ronaldo|siuu", "9:Ali Dia"],
      "deep": [["Ali Dia", "one-line explainer", "https://source"], ["...", "...", "..."]]
    }
  ]
}
```
- Every puzzle needs exactly 7 prompts.
- `list` entries are `score:Answer|alias|alias`. The score (1-10) sets the starting tier. See the guide below.
- `deep` holds the explainers shown on the results screen. Put your two most obscure answers there.
- After adding or editing a puzzle, run `python tools/check_puzzles.py`. It catches broken files and two answers that would match the same guess, shows how many answers land in each tier, and updates `puzzles/index.json` for you.

### Scoring guide: how niche is an answer?

Score the answer by asking who would come up with it for *this prompt*, not just how famous it is.

| Score | Tier | Points | Who says it |
|---|---|---|---|
| 1-2 | NPC | 10 | The first thing almost everyone types. Your mum has heard of it. |
| 3 | Casual | 15 | Comes to mind right after the obvious ones for anyone who uses the apps. |
| 4-5 | Tuned In | 30 | Known to regular scrollers, or a very famous name that isn't an obvious fit. |
| 6-7 | Ball Knower | 60 | You have to actually follow the scene. Casuals wouldn't think of it. |
| 8 | Deep Lore | 85 | Fan-community knowledge or older internet history. Most players won't recognise it. |
| 9-10 | Elite Ball Knowledge | 100 | Extremely niche. Only dedicated fans or internet historians know it exists. |

Two rules keep the top tiers honest:

- **Fame caps the tier.** A household name never goes above Tuned In, even if few people would say it for this prompt (Snoop Dogg for "rapper with an ad-lib" is a 5, not an 8).
- **Elite stays small.** Aim for 2 to 5 Elite answers per prompt. If lots of answers feel Elite, most of them are really Deep Lore.

## How tiers work

1. **Starting point**: the score in the puzzle file.
2. **Live rarity**: once 3+ other players have answered a prompt, the share of players who gave each answer blends in. The puzzle score counts like 50 imaginary players, so a handful of real players only nudges a tier and hundreds decide it. 25%+ of players → NPC, under 1% → Elite Ball Knowledge.
3. **Overrides**: anything you set in the tier editor beats both. **AUTO** in the editor removes your override.

## What the backend protects against

- Players can't read each other's games or write to the tables directly. The browser can only call three functions (`submit_play`, `answer_counts`, `is_admin`) and read tier overrides.
- One game per player per day, and each game must have the right shape (7 answers, a believable score, not a future date).
- At most 30 games per puzzle from one network address, so one person can't flood the rarity numbers. The address is stored only as a salted hash.
- A finished game is saved in the browser after every answer, so refreshing mid-game resumes it (with the clock still running) instead of giving a second try. If the backend is unreachable the game still works, and the result is sent on the next visit.

## Known limits

- Answers live in the puzzle JSON, so a determined player could peek. Moving answer checking server-side would fix that if it ever matters.
- A player who clears their browser data counts as a new player.

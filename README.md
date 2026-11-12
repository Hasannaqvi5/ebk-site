# EBK

Daily rare-answer trivia about internet culture: memes, TikTok, YouTube, Insta, and internet ball knowledge.

## How it fits together

- **`index.html`**: the whole game in one file (no build step). The same file also runs as the Claude artifact.
- **`puzzles/`**: one JSON file per day (`2026-11-13.json`) plus `index.json` listing the available dates. The game loads today's file, or the latest one before today.
- **Supabase**: stores every finished game (for live rarity, "X% of players said this") and your tier overrides. Free tier is plenty.
- **Hosting**: any static host works (Vercel, Netlify, Cloudflare Pages, GitHub Pages).

## Setup (about 15 minutes)

1. **Supabase**: create a free project at supabase.com. Open **SQL Editor**, paste `supabase/schema.sql`, and run it.
2. **Keys**: in **Project Settings → API**, copy the Project URL and the `anon` public key into `config.js`.
3. **Auth** (for the tier editor): in **Authentication → URL Configuration**, set the Site URL to your site's address. Email magic links are on by default.
4. **Deploy**: push this folder to a GitHub repo and import it into Vercel / Netlify / Cloudflare Pages as a static site (no build command, output directory = root). GitHub Pages also works.
5. **Make yourself admin**: visit `https://your-site/#admin`, enter your email, and click the link you get. Then in the Supabase SQL Editor run:
   ```sql
   insert into public.admins (user_id)
   select id from auth.users where email = 'you@example.com';
   ```
   Reload the site, finish a game, and an **EDIT TIERS** button shows up on the results screen.

## Local testing

```bash
python3 -m http.server 8000
# open http://localhost:8000
```
Use **Reset (test)** on the results screen to replay the same day.

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
      "list": ["2:Cristiano Ronaldo|ronaldo|siuu", "9:Ali Dia"],
      "deep": [["Ali Dia", "one-line explainer", "https://source"], ["...", "...", "..."]]
    }
  ]
}
```
- `list` entries are `score:Answer|alias|alias`. Score 1-10 sets the starting tier (1-2 NPC, 3 Casual, 4-5 Tuned In, 6-7 Ball Knower, 8 Deep Lore, 9-10 Elite Ball Knowledge). Without scores, tiers come from list position.
- After every new puzzle, add its date to `puzzles/index.json`.

## How tiers work

1. **Starting point**: the obscurity score in the puzzle file.
2. **Live rarity**: once 3+ other players have answered a prompt, the share of players who gave each answer blends in (more players = more weight). 25%+ of players → NPC, under 1% → Elite Ball Knowledge.
3. **Overrides**: anything you set in the tier editor beats both.

## Known limits (v1)

- Answers live in the puzzle JSON, so a determined player could peek. Fine for now; move validation server-side later if it matters.
- Plays aren't rate-limited. If spam shows up, add a Supabase Edge Function or Captcha in front of inserts.

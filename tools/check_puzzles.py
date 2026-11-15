#!/usr/bin/env python3
"""Check every puzzle file before you publish it.

    python tools/check_puzzles.py

What it does:
  * checks each puzzles/YYYY-MM-DD.json has the shape the game expects
  * catches two answers in one prompt that would match the same typed guess
  * prints how many answers land in each tier, so you can see the spread
  * rewrites puzzles/index.json so it lists exactly the puzzle files that exist

Exits with an error (and a list of problems) if anything is wrong.
"""
import json
import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUZZLES = ROOT / "puzzles"
TIERS = ["NPC Trap", "Local Buzz", "On The FYP", "Trending", "Went Viral", "Phenomenon"]
PROMPTS = 10                # lore checks per puzzle (QN / MAXQ in index.html)
OLD_PROMPTS = 7             # puzzles dated before TEN_FROM may still have 7
TEN_FROM = "2026-11-12"     # first puzzle date with 10 lore checks
TRAPS = 3                   # answers scored 1 per lore check
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
SCORE_RE = re.compile(r"^\s*(10|[1-9])\s*:\s*(.+)$", re.S)


def norm(s):
    """Same normalisation the game uses to compare a typed guess with an answer."""
    s = unicodedata.normalize("NFD", s)
    s = "".join(c for c in s if not 0x300 <= ord(c) <= 0x36F).lower()
    s = s.replace("&", " and ")
    s = re.sub(r"['’`]", "", s)
    s = re.sub(r"[^a-z0-9]+", " ", s).strip()
    s = re.sub(r"^the ", "", s)
    return s.replace(" ", "")


def keys_for(name, aliases):
    raw = [name] + name.split(" / ")
    raw.append(re.sub(r"\s*\([^)]*\)", "", name))
    raw += re.findall(r"\(([^)]*)\)", name)
    raw += aliases
    return {k for k in (norm(r) for r in raw) if len(k) >= 2}


def tier_from_score(s):
    # 1 = NPC Trap, 2-3 = Local Buzz, 4-5 = On The FYP, 6-7 = Trending, 8 = Went Viral, 9-10 = Phenomenon
    return 0 if s == 1 else 1 if s <= 3 else 2 if s <= 5 else 3 if s <= 7 else 4 if s == 8 else 5


def tier_from_position(i, n):
    """Same fallback the game uses for entries without a score: first 3 are traps, rest by position."""
    if i < TRAPS:
        return 0
    f = (i - TRAPS) / max(1, n - TRAPS)
    return 1 if f < .15 else 2 if f < .40 else 3 if f < .65 else 4 if f < .88 else 5


def read_json(path):
    # utf-8-sig: files saved by some Windows editors start with a byte-order mark; browsers accept it.
    return json.loads(path.read_text(encoding="utf-8-sig"))


def check_file(path, errors, warnings):
    where = path.name
    try:
        data = read_json(path)
    except Exception as e:
        errors.append(f"{where}: not valid JSON ({e})")
        return None
    if path.read_bytes()[:3] == b"\xef\xbb\xbf":
        warnings.append(f"{where}: starts with a byte-order mark (works, but some tools reject it)")
    if data.get("date") != path.stem:
        errors.append(f'{where}: "date" is {data.get("date")!r} but the file name says {path.stem}')
    if not isinstance(data.get("num"), int) or data["num"] < 1:
        errors.append(f'{where}: "num" must be a whole number, 1 or higher')
    prompts = data.get("prompts")
    allowed = (PROMPTS,) if path.stem >= TEN_FROM else (OLD_PROMPTS, PROMPTS)
    if not isinstance(prompts, list) or len(prompts) not in allowed:
        got = len(prompts) if isinstance(prompts, list) else "no prompts list"
        need = f"exactly {PROMPTS}" if len(allowed) == 1 else f"{OLD_PROMPTS} or {PROMPTS}"
        errors.append(f"{where}: needs {need} prompts, got {got}")
        return None

    is_ten = len(prompts) == PROMPTS
    spread = []
    for pi, p in enumerate(prompts):
        at = f"{where} prompt {pi + 1}"
        if not str(p.get("text") or p.get("drop") or "").strip():
            errors.append(f"{at}: missing text")
        if not p.get("drop"):
            warnings.append(f"{at}: missing 'drop' field (will fall back to auto-rewrite)")
        entries = [str(s) for s in (p.get("list") or []) if str(s).strip()]
        if len(entries) < 10:
            errors.append(f"{at}: only {len(entries)} answers (give players at least 10)")
            if not entries:
                continue
        seen, names, counts, unscored = {}, set(), [0] * 6, 0
        ones_count = 0
        for i, entry in enumerate(entries):
            m = SCORE_RE.match(entry)
            score, body = (int(m.group(1)), m.group(2)) if m else (None, entry)
            name, *aliases = [x.strip() for x in body.split("|")]
            if not name:
                errors.append(f"{at}: empty answer name in {entry!r}")
                continue
            if score is None:
                unscored += 1
            else:
                if score == 1:
                    ones_count += 1
            counts[tier_from_score(score) if score is not None else tier_from_position(i, len(entries))] += 1
            names.add(name)
            if len(name) > 80:
                errors.append(f"{at}: {name!r} is longer than 80 characters")
            if norm(name) == "skip":
                errors.append(f'{at}: an answer cannot be called "skip" (that word skips the prompt)')
            keys = keys_for(name, aliases)
            if not keys:
                errors.append(f"{at}: {name!r} can never be matched (too short once normalised)")
            for k in keys:
                if k in seen and seen[k] != name:
                    errors.append(f"{at}: {seen[k]!r} and {name!r} both match the guess {k!r}")
                seen.setdefault(k, name)
        # Unscored lists get their traps from position (first 3), so the rule only applies to scores.
        if is_ten and unscored < len(entries) and ones_count != TRAPS:
            errors.append(f"{at}: must have exactly {TRAPS} answers scored 1 (NPC traps), found {ones_count}")
        if unscored and unscored != len(entries):
            warnings.append(f"{at}: {unscored} answers have no score while the rest do")
        elif unscored:
            warnings.append(f"{at}: no scores, tiers will come from list position")
        for t, c in enumerate(counts):
            if c == 0:
                warnings.append(f"{at}: nothing in the {TIERS[t]} tier")
        for b in p.get("ban") or []:
            if norm(str(b)) in seen:
                errors.append(f"{at}: {b!r} is banned but also matches the answer {seen[norm(str(b))]!r}")
        deep = p.get("deep") or []
        if len(deep) < 2:
            warnings.append(f"{at}: fewer than 2 deep-cut explainers")
        for d in deep:
            if not isinstance(d, list) or len(d) < 2:
                errors.append(f"{at}: deep entry {d!r} should be [answer, explainer, link]")
                continue
            if d[0] not in names:
                errors.append(f"{at}: deep entry {d[0]!r} is not one of the answers")
            if len(d) > 2 and d[2] and not str(d[2]).startswith("https://"):
                errors.append(f"{at}: deep link for {d[0]!r} must start with https://")
        display_label = p.get("drop") or p.get("text", "")
        spread.append((display_label, len(entries), counts))
    return spread


def main():
    errors, warnings = [], []
    files = sorted(f for f in PUZZLES.glob("*.json") if DATE_RE.match(f.stem))
    if not files:
        errors.append("no puzzle files found in puzzles/")
    nums = {}
    for f in files:
        spread = check_file(f, errors, warnings)
        try:
            n = read_json(f).get("num")
            if n in nums:
                errors.append(f'{f.name}: "num" {n} is already used by {nums[n]}')
            nums.setdefault(n, f.name)
        except Exception:
            pass
        if spread:
            print(f"\n{f.name}")
            print("  " + "answers".rjust(7) + "".join(t.rjust(14) for t in TIERS))
            for text, total, counts in spread:
                print("  " + str(total).rjust(7) + "".join(str(c).rjust(14) for c in counts) + "   " + text)

    dates = [f.stem for f in files]
    index = PUZZLES / "index.json"
    try:
        current = read_json(index)
    except Exception:
        current = None
    if not errors and current != dates:
        index.write_text(json.dumps(dates) + "\n", encoding="utf-8")
        print(f"\nupdated puzzles/index.json ({len(dates)} puzzles)")

    for w in warnings:
        print("warning:", w)
    if errors:
        print()
        for e in errors:
            print("ERROR:", e)
        print(f"\n{len(errors)} problem(s) found. Nothing is safe to publish yet.")
        return 1
    print(f"\nAll good: {len(files)} puzzle file(s) checked.")
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())

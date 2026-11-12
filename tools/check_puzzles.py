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
TIERS = ["NPC", "Casual", "Tuned In", "Ball Knower", "Deep Lore", "Elite"]
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
    return 0 if s <= 2 else 1 if s == 3 else 2 if s <= 5 else 3 if s <= 7 else 4 if s == 8 else 5


def tier_from_position(i, n):
    f = i / n
    return 0 if f < .08 else 1 if f < .20 else 2 if f < .40 else 3 if f < .65 else 4 if f < .88 else 5


def check_file(path, errors, warnings):
    where = path.name
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:
        errors.append(f"{where}: not valid JSON ({e})")
        return None
    if data.get("date") != path.stem:
        errors.append(f'{where}: "date" is {data.get("date")!r} but the file name says {path.stem}')
    if not isinstance(data.get("num"), int) or data["num"] < 1:
        errors.append(f'{where}: "num" must be a whole number, 1 or higher')
    prompts = data.get("prompts")
    if not isinstance(prompts, list) or len(prompts) != 7:
        errors.append(f"{where}: needs exactly 7 prompts")
        return None

    spread = []
    for pi, p in enumerate(prompts):
        at = f"{where} prompt {pi + 1}"
        if not str(p.get("text") or "").strip():
            errors.append(f"{at}: missing text")
        entries = [str(s) for s in (p.get("list") or []) if str(s).strip()]
        if len(entries) < 10:
            errors.append(f"{at}: only {len(entries)} answers (give players at least 10)")
            if not entries:
                continue
        seen, names, counts, unscored = {}, set(), [0] * 6, 0
        for i, entry in enumerate(entries):
            m = SCORE_RE.match(entry)
            score, body = (int(m.group(1)), m.group(2)) if m else (None, entry)
            name, *aliases = [x.strip() for x in body.split("|")]
            if not name:
                errors.append(f"{at}: empty answer name in {entry!r}")
                continue
            if score is None:
                unscored += 1
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
        spread.append((p.get("text", ""), len(entries), counts))
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
            n = json.loads(f.read_text(encoding="utf-8")).get("num")
            if n in nums:
                errors.append(f'{f.name}: "num" {n} is already used by {nums[n]}')
            nums.setdefault(n, f.name)
        except Exception:
            pass
        if spread:
            print(f"\n{f.name}")
            print("  " + "answers".rjust(7) + "".join(t.rjust(13) for t in TIERS))
            for text, total, counts in spread:
                print("  " + str(total).rjust(7) + "".join(str(c).rjust(13) for c in counts) + "   " + text)

    dates = [f.stem for f in files]
    index = PUZZLES / "index.json"
    try:
        current = json.loads(index.read_text(encoding="utf-8"))
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

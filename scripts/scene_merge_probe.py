#!/usr/bin/env python3
"""Measurements behind docs/scene-format.md: how four ways of writing the same scene behave under git.

    python3 scripts/scene_merge_probe.py            # the merge table and the size table (markdown on stdout)
    python3 scripts/scene_merge_probe.py --quick    # fewer trials and no 1e5 row, for a fast check
    python3 scripts/scene_merge_probe.py --selftest # the serialisers round-trip and the key merge is checked

One in-memory scene model (entity id -> {field: text}) is written four ways:

  positional  what scene v1 does structurally: entities numbered by position, a count row, every field written
              (defaults too), a vector as three rows. It is a model of v1's structure, not v1's row names.
  sections    a `[node <id>]` header, then `field = value` lines; non-default fields only; sorted by id.
  toml        `[node.<id>]` and `[node.<id>.<component>]` tables with typed values; sorted by id.
  rows        the proposed v2: one self-contained `<id>.<field> = value` row per line, sorted by key.

and the rows form in four more layouts: an empty line after every row; every field of a present component written
(defaults too); both; and one file per entity.

Two editors start from one base and each apply N random operations (set a field, add, delete, reparent). The
three files go through `git merge-file`, git's own three-way file merge. A trial has a *true* conflict when both
changed one key to different values, or one deleted an entity the other changed. Reported per format:

  false conflict  git reports a conflict in a trial that has no true conflict
  wrong           git merges cleanly but the result is not the key-wise merge of the two edits (or does not parse)
  missed          git merges cleanly in a trial that has a true conflict

`rows + driver` is the key-wise three-way merge itself (the prototype of `ludens merge`).

The size table writes scenes of 1e3 / 1e4 / 1e5 entities and measures bytes, gzip bytes, the git pack after
`git gc`, the pack growth over 20 commits of 5 edits each, and the time Python takes to split the rows.
"""
import argparse
import gzip
import random
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# field -> default text. A component is present when its bare name is a field with value "+".
SCHEMA = [
    ("node", "-"), ("name", '""'),
    ("transform.pos", "0 0 0"), ("transform.rot", "0 0 0 1"), ("transform.scale", "1 1 1"),
    ("body", "-"), ("body.kind", "static"), ("body.mass", "0"), ("body.friction", "-1"),
    ("body.restitution", "0"), ("body.lin_damping", "0"), ("body.ang_damping", "0"),
    ("body.gravity_scale", "1"), ("body.ccd", "0"),
    ("collider", "-"), ("collider.shape", "box"), ("collider.size", "0.5 0.5 0.5"),
    ("collider.category", "1"), ("collider.mask", "4294967295"),
    ("mesh", "-"), ("mesh.shape", "box"),
    ("material", "-"), ("material.kind", "color"), ("material.color", "1 1 1"),
    ("material.roughness", "0.5"), ("material.metallic", "0"),
    ("light", "-"), ("light.kind", "point"), ("light.range", "10"), ("light.intensity", "1"),
    ("light.color", "1 1 1"), ("light.shadow", "false"),
]
DEFAULT = dict(SCHEMA)
FIELDS = [f for f, _ in SCHEMA]
COMPONENTS = ["body", "collider", "mesh", "material", "light"]
VECTORS = {f: len(d.split()) for f, d in SCHEMA if " " in d}
AXES = "xyzw"

Scene = dict  # id -> {field: text}; only non-default fields are stored


def new_id(rng: random.Random) -> str:
    return f"{rng.getrandbits(64):016x}"


def num(rng: random.Random, lo: float, hi: float) -> str:
    text = f"{rng.uniform(lo, hi):.3f}".rstrip("0").rstrip(".") or "0"
    return "0" if text == "-0" else text  # one spelling of zero, as a canonical writer would give


def vec(rng: random.Random, n: int, lo: float, hi: float) -> str:
    return " ".join(num(rng, lo, hi) for _ in range(n))


def new_entity(rng: random.Random, parents: list[str]) -> dict:
    e = {"name": f'"e{rng.getrandbits(20)}"', "transform.pos": vec(rng, 3, -200, 200)}
    if parents and rng.random() < 0.3:
        e["node"] = rng.choice(parents)
    roll = rng.random()
    if roll < 0.9:  # a prop: static or dynamic
        e.update({"body": "+", "collider": "+", "mesh": "+", "material": "+"})
        e["collider.size"] = vec(rng, 3, 0.2, 4)
        e["material.color"] = vec(rng, 3, 0, 1)
        if roll > 0.7:
            e["body.kind"] = "dynamic"
            e["body.mass"] = num(rng, 1, 50)
    elif roll < 0.95:
        e.update({"light": "+", "light.range": num(rng, 2, 30), "light.intensity": num(rng, 0.2, 8)})
    return e


def make_scene(rng: random.Random, n: int) -> tuple[Scene, list[str]]:
    scene: Scene = {}
    order: list[str] = []
    for _ in range(n):
        i = new_id(rng)
        scene[i] = new_entity(rng, order[-50:])
        order.append(i)
    return scene, order


def settable(e: dict) -> list[str]:
    out = ["transform.pos", "name"]
    for c in COMPONENTS:
        if e.get(c) == "+":
            out += [f for f in FIELDS if f.startswith(c + ".")]
    return out


def random_value(rng: random.Random, field: str) -> str:
    if field in VECTORS:
        return vec(rng, VECTORS[field], -5, 5)
    if field == "name":
        return f'"e{rng.getrandbits(20)}"'
    d = DEFAULT[field]
    if d in ("true", "false"):
        return "true" if rng.random() < 0.5 else "false"
    if d.lstrip("-").replace(".", "").isdigit():
        return num(rng, 0, 9)
    return rng.choice(["static", "dynamic", "kinematic", "sphere", "capsule", "pbr", "spot"])


def edit(rng: random.Random, scene: Scene, order: list[str], ops: int) -> tuple[Scene, list[str]]:
    """A copy of the scene after `ops` random operations. `order` is the positional order (v1 keeps it)."""
    s = {i: dict(e) for i, e in scene.items()}
    o = list(order)
    for _ in range(ops):
        r = rng.random()
        if r < 0.70 and o:
            i = rng.choice(o)
            f = rng.choice(settable(s[i]))
            v = random_value(rng, f)
            if v == DEFAULT[f]:
                s[i].pop(f, None)
            else:
                s[i][f] = v
        elif r < 0.85:
            i = new_id(rng)
            s[i] = new_entity(rng, o[-50:])
            o.append(i)  # a new body takes the next index
        elif r < 0.95 and len(o) > 2:
            i = rng.choice(o)
            del s[i]
            o.remove(i)  # the positional form compacts: every later index shifts
        elif o:
            i, p = rng.choice(o), rng.choice(o)
            if i != p:
                s[i]["node"] = p
    return s, o


# ------------------------------------------------------------------------------------------------ the four forms

def to_rows(scene: Scene, order: list[str]) -> str:
    lines = []
    for i, e in scene.items():
        lines.append(f"{i}.node = {e.get('node', '-')}")
        lines += [f"{i}.{f} = {v}" for f, v in e.items() if f != "node"]
    return "ludens-scene 2\n" + "".join(l + "\n" for l in sorted(lines))


def to_rows_spaced(scene: Scene, order: list[str]) -> str:
    """The same rows with an empty line after each: two changed rows are then never adjacent lines."""
    head, *rows = to_rows(scene, order).split("\n")[:-1]
    return head + "\n" + "".join(r + "\n\n" for r in rows)


def to_rows_full(scene: Scene, order: list[str]) -> str:
    """Rows with every field of every present component written, defaults too: setting a field then changes a
    line in place and never inserts one."""
    lines = []
    for i, e in scene.items():
        for f in FIELDS:
            c = f.split(".")[0]
            if f in COMPONENTS:
                if e.get(f) == "+":
                    lines.append(f"{i}.{f} = +")
            elif c in ("node", "name", "transform") or e.get(c) == "+":
                lines.append(f"{i}.{f} = {e.get(f, DEFAULT[f])}")
    return "ludens-scene 2\n" + "".join(l + "\n" for l in sorted(lines))


def to_rows_full_spaced(scene: Scene, order: list[str]) -> str:
    head, *rows = to_rows_full(scene, order).split("\n")[:-1]
    return head + "\n" + "".join(r + "\n\n" for r in rows)


def from_rows_full(text: str) -> Scene:
    scene = from_rows(text)
    return {i: {f: v for f, v in e.items() if v != DEFAULT.get(f)} for i, e in scene.items()}


def from_rows(text: str) -> Scene:
    scene: Scene = {}
    lines = text.split("\n")
    if lines[0] != "ludens-scene 2":
        raise ValueError("header")
    for line in lines[1:]:
        if not line:
            continue
        key, value = line.split(" = ", 1)
        i, f = key.split(".", 1)
        if f in scene.setdefault(i, {}):
            raise ValueError("duplicate key")
        if f != "node" or value != "-":
            scene[i][f] = value
    return scene


def to_sections(scene: Scene, order: list[str]) -> str:
    out = ["# scene"]
    for i in sorted(scene):
        out.append(f"[node {i}]")
        out += [f"{f} = {v}" for f, v in sorted(scene[i].items())]
        out.append("")
    return "\n".join(out) + "\n"


def from_sections(text: str) -> Scene:
    scene: Scene = {}
    cur = None
    for line in text.split("\n")[1:]:
        if not line:
            continue
        if line.startswith("[node "):
            cur = line[6:-1]
            if cur in scene:
                raise ValueError("duplicate section")
            scene[cur] = {}
        else:
            f, v = line.split(" = ", 1)
            if cur is None or f in scene[cur]:
                raise ValueError("stray or duplicate field")
            scene[cur][f] = v
    return scene


def toml_value(v: str, field: str = "") -> str:
    if field == "node":  # an entity id: always a string (an id such as 6315684974376e56 also reads as a number)
        return f'"{v}"'
    if v.startswith('"') or v in ("true", "false"):
        return v
    parts = v.split()
    try:
        [float(p) for p in parts]
    except ValueError:
        return f'"{v}"'
    return parts[0] if len(parts) == 1 else "[" + ", ".join(parts) + "]"


def to_toml(scene: Scene, order: list[str]) -> str:
    out = ["version = 2", ""]
    for i in sorted(scene):
        e = scene[i]
        out.append(f"[node.{i}]")
        out += [f"{f} = {toml_value(v, f)}" for f, v in sorted(e.items()) if "." not in f and f not in COMPONENTS]
        out.append("")
        groups: dict[str, list[str]] = {}
        for f, v in sorted(e.items()):
            if f in COMPONENTS:
                groups.setdefault(f, [])
            elif "." in f:
                c, k = f.split(".", 1)
                groups.setdefault(c, []).append(f"{k} = {toml_value(v)}")
        for c in sorted(groups):
            out.append(f"[node.{i}.{c}]")
            out += groups[c]
            out.append("")
    return "\n".join(out) + "\n"


def from_toml(text: str) -> Scene:
    import tomllib
    doc = tomllib.loads(text)  # raises on a duplicate table or key

    def back(v) -> str:
        if isinstance(v, bool):
            return "true" if v else "false"
        if isinstance(v, list):
            return " ".join(back(x) for x in v)
        if isinstance(v, str):
            return v if v in ("static", "dynamic", "kinematic", "sphere", "capsule", "pbr", "spot", "box", "color",
                              "point") else f'"{v}"'
        return repr(v) if isinstance(v, float) else str(v)

    scene: Scene = {}
    for i, e in doc.get("node", {}).items():
        scene[i] = {}
        for k, v in e.items():
            if k == "node":
                scene[i][k] = v
            elif isinstance(v, dict):
                if k in COMPONENTS:
                    scene[i][k] = "+"
                for k2, v2 in v.items():
                    scene[i][f"{k}.{k2}"] = back(v2)
            else:
                scene[i][k] = back(v)
    return scene


def to_positional(scene: Scene, order: list[str]) -> str:
    out = ["# scene v1 structure", f"count = {len(order)}"]
    for n, i in enumerate(order):
        e = scene[i]
        out.append(f"e.{n}.id = {i}")
        for f in FIELDS:
            v = e.get(f, DEFAULT[f])
            if f in VECTORS:
                out += [f"e.{n}.{f}.{AXES[k]} = {p}" for k, p in enumerate(v.split())]
            else:
                out.append(f"e.{n}.{f} = {v}")
    return "\n".join(out) + "\n"


def from_positional(text: str) -> Scene:
    rows: dict[str, str] = {}
    for line in text.split("\n")[1:]:
        if not line:
            continue
        k, v = line.split(" = ", 1)
        if k in rows:
            raise ValueError("duplicate row")
        rows[k] = v
    count = int(rows["count"])
    if sum(1 for k in rows if k.endswith(".id")) != count:
        raise ValueError("count row does not match the entities present")
    scene: Scene = {}
    for n in range(count):
        e = {}
        for f in FIELDS:
            if f in VECTORS:
                v = " ".join(rows[f"e.{n}.{f}.{AXES[k]}"] for k in range(VECTORS[f]))
            else:
                v = rows[f"e.{n}.{f}"]
            if v != DEFAULT[f]:
                e[f] = v
        if rows[f"e.{n}.id"] in scene:
            raise ValueError("one entity twice")
        scene[rows[f"e.{n}.id"]] = e
    if len(rows) != 1 + count * (1 + len(FIELDS) + sum(VECTORS.values()) - len(VECTORS)):
        raise ValueError("rows left over")
    return scene


FORMS = {
    "positional (v1 structure)": (to_positional, from_positional),
    "sections": (to_sections, from_sections),
    "toml": (to_toml, from_toml),
    "rows (v2)": (to_rows, from_rows),
    "rows, an empty line between rows": (to_rows_spaced, from_rows),
    "rows, every field written": (to_rows_full, from_rows_full),
    "rows, every field written, an empty line between rows": (to_rows_full_spaced, from_rows_full),
}


# ------------------------------------------------------------------------------------------------- the key merge

def keys(scene: Scene) -> dict[str, str]:
    out = {}
    for i, e in scene.items():
        out[f"{i}.node"] = e.get("node", "-")
        for f, v in e.items():
            if f != "node":
                out[f"{i}.{f}"] = v
    return out


def key_merge(base: Scene, a: Scene, b: Scene) -> tuple[Scene, list[str]]:
    """The key-wise three-way merge and the keys in true conflict. On a conflict the result keeps a's value."""
    kb, ka, kc = keys(base), keys(a), keys(b)
    merged, conflicts = {}, []
    for k in sorted(set(kb) | set(ka) | set(kc)):
        vb, va, vc = kb.get(k), ka.get(k), kc.get(k)
        if va == vc:
            v = va
        elif va == vb:
            v = vc
        elif vc == vb:
            v = va
        else:
            v = va
            conflicts.append(k)
        if v is not None:
            merged[k] = v
    # an entity one side deleted and the other changed: its rows survive without a `node` row
    ents = {k.split(".", 1)[0] for k in merged}
    for i in sorted(ents):
        if f"{i}.node" not in merged:
            conflicts.append(f"{i}.node")
    return from_rows(to_rows_from_keys(merged)) if not conflicts else {}, conflicts


def to_rows_from_keys(k: dict[str, str]) -> str:
    return "ludens-scene 2\n" + "".join(f"{key} = {k[key]}\n" for key in sorted(k))


def git_merge_file(d: Path, base: str, a: str, b: str) -> tuple[bool, str]:
    (d / "base").write_text(base)
    (d / "a").write_text(a)
    (d / "b").write_text(b)
    r = subprocess.run(["git", "merge-file", "-p", str(d / "a"), str(d / "base"), str(d / "b")],
                       capture_output=True, text=True)
    if r.returncode < 0 or r.returncode > 127:
        raise RuntimeError(r.stderr)
    return r.returncode == 0, r.stdout


def git_merge_repo(d: Path, base: str, a: str, b: str) -> bool:
    """The same three files through a real `git merge` of two branches: True when it merges cleanly."""
    repo = d / "repo"
    if repo.exists():
        subprocess.run(["rm", "-rf", str(repo)], check=True)
    repo.mkdir()

    def git(*args, ok=(0,)):
        r = subprocess.run(["git", "-c", "user.name=probe", "-c", "user.email=probe@example.invalid", *args],
                           cwd=repo, capture_output=True, text=True)
        if r.returncode not in ok:
            raise RuntimeError(r.stderr + r.stdout)
        return r.returncode

    git("init", "-q", "-b", "main")
    (repo / "s").write_text(base)
    git("add", "s"); git("commit", "-q", "-m", "base")
    git("checkout", "-q", "-b", "a"); (repo / "s").write_text(a); git("commit", "-q", "-am", "a")
    git("checkout", "-q", "main"); git("checkout", "-q", "-b", "b"); (repo / "s").write_text(b)
    git("commit", "-q", "-am", "b")
    return git("merge", "-q", "--no-edit", "a", ok=(0, 1)) == 0


def entity_files(scene: Scene, spaced: bool) -> dict[str, str]:
    """One file per entity: its rows, sorted."""
    write = to_rows_spaced if spaced else to_rows
    return {i: write({i: e}, [i]) for i, e in scene.items()}


def merge_per_entity(d: Path, base: Scene, a: Scene, b: Scene, spaced: bool) -> tuple[bool, Scene]:
    """What git does when every entity is its own file: untouched and one-sided files merge by themselves, a file
    both sides changed goes through the file merge, and delete against change is a conflict."""
    fb, fa, fc = entity_files(base, spaced), entity_files(a, spaced), entity_files(b, spaced)
    merged: Scene = {}
    for i in set(fb) | set(fa) | set(fc):
        tb, ta, tc = fb.get(i), fa.get(i), fc.get(i)
        if ta == tc or tc == tb:
            text = ta
        elif ta == tb:
            text = tc
        elif ta is None or tc is None or tb is None:
            return False, {}
        else:
            clean, text = git_merge_file(d, tb, ta, tc)
            if not clean:
                return False, {}
        if text is not None:
            merged.update(from_rows(text))
    return True, merged


PER_ENTITY = {"rows, one file per entity": False, "rows, one file per entity, an empty line between rows": True}


def merge_table(entities: int, trials: int, ops_list: list[int], seed: int) -> list[str]:
    out = [f"### Merge: {entities} entities, {trials} trials per cell, two editors with N operations each", "",
           "| form | N | trials with a true conflict | false conflict | wrong | missed |", "|---|---:|---:|---:|---:|---:|"]
    agree = total = 0
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        for ops in ops_list:
            stats = {name: [0, 0, 0] for name in [*FORMS, *PER_ENTITY]}  # false, wrong, missed
            driver_conflicts = true_trials = 0
            for t in range(trials):
                rng = random.Random(f"{seed}/{ops}/{t}")
                base, order = make_scene(rng, entities)
                a, oa = edit(random.Random(f"{seed}/{ops}/{t}/a"), base, order, ops)
                b, ob = edit(random.Random(f"{seed}/{ops}/{t}/b"), base, order, ops)
                want, conflicts = key_merge(base, a, b)
                true_conflict = bool(conflicts)
                true_trials += true_conflict
                driver_conflicts += true_conflict
                for name, (write, read) in FORMS.items():
                    clean, text = git_merge_file(d, write(base, order), write(a, oa), write(b, ob))
                    if t < 4:  # cross-check git merge-file against a real two-branch merge
                        total += 1
                        agree += git_merge_repo(d, write(base, order), write(a, oa), write(b, ob)) == clean
                    if true_conflict:
                        stats[name][2] += clean
                    elif not clean:
                        stats[name][0] += 1
                    else:
                        try:
                            ok = read(text) == want
                        except Exception:
                            ok = False
                        stats[name][1] += not ok
                for name, spaced in PER_ENTITY.items():
                    clean, got = merge_per_entity(d, base, a, b, spaced)
                    if true_conflict:
                        stats[name][2] += clean
                    elif not clean:
                        stats[name][0] += 1
                    else:
                        stats[name][1] += got != want
            free = trials - true_trials
            pct = lambda n, of: f"{n} / {of}" + (f" ({100 * n / of:.0f} %)" if of else "")
            for name in stats:
                f, w, m = stats[name]
                out.append(f"| {name} | {ops} | {true_trials} | {pct(f, free)} | {pct(w, free)} | {pct(m, true_trials)} |")
            out.append(f"| rows (v2) + key merge driver | {ops} | {true_trials} | {pct(0, free)} | {pct(0, free)} | "
                       f"{pct(true_trials - driver_conflicts, true_trials)} |")
    out += ["", f"`git merge-file` and a real two-branch `git merge` gave the same clean / conflict answer in "
                f"{agree} of {total} cross-checked merges."]
    return out


# ----------------------------------------------------------------------------------------------------- the sizes

def pack_bytes(repo: Path) -> int:
    subprocess.run(["git", "gc", "-q"], cwd=repo, check=True, capture_output=True)
    return sum(p.stat().st_size for p in (repo / ".git" / "objects").rglob("*") if p.is_file())


def write_scene(repo: Path, text: str, shards: int):
    """One file (shards 1), `shards` files split by the first hex digits of the entity id, or one file per entity
    under a two-digit directory (shards 0). Only files whose content changed are rewritten."""
    if shards == 1:
        (repo / "world.scene").write_text(text)
        return
    digits = 16 if shards == 0 else len(f"{shards - 1:x}")
    buckets: dict[str, list[str]] = {}
    for line in text.split("\n")[1:]:
        if line:
            buckets.setdefault(line[:digits], []).append(line)
    root = repo / "world.scene"
    root.mkdir(exist_ok=True)
    path = lambda k: root / k[:2] / f"{k}.rows" if shards == 0 else root / f"{k}.rows"
    live = set()
    for k, lines in buckets.items():
        p = path(k)
        new = "ludens-scene 2\n" + "\n".join(lines) + "\n"
        live.add(p)
        if not p.exists() or p.read_text() != new:
            p.parent.mkdir(exist_ok=True)
            p.write_text(new)
    for p in root.rglob("*.rows"):
        if p not in live:
            p.unlink()


def size_table(sizes: list[int], seed: int) -> list[str]:
    out = ["### Size and git storage", "",
           "| entities | form | rows | bytes | gzip bytes | pack after gc | pack growth, 20 commits of 5 edits | "
           "largest file rewritten per commit | Python split of all rows |",
           "|---:|---|---:|---:|---:|---:|---:|---:|---:|"]
    for n in sizes:
        rng = random.Random(f"{seed}/size/{n}")
        base, order = make_scene(rng, n)
        forms = [("positional (v1 structure)", to_positional, 1), ("sections, one file", to_sections, 1),
                 ("rows (v2), one file", to_rows, 1), ("rows (v2), 256 shards", to_rows, 256),
                 ("rows, every field written, one file", to_rows_full, 1),
                 ("rows, every field written, 256 shards", to_rows_full, 256)]
        if n <= 10000:  # 1e5 files in one git repository is a different measurement; not run here
            forms.append(("rows (v2), one file per entity", to_rows, 0))
        for name, write, shards in forms:
            text = write(base, order)
            t0 = time.perf_counter()
            parsed = sum(1 for line in text.split("\n") if line and line.partition(" = ")[1])
            split_ms = (time.perf_counter() - t0) * 1000
            with tempfile.TemporaryDirectory() as tmp:
                repo = Path(tmp)
                git = lambda *a: subprocess.run(["git", "-c", "user.name=probe", "-c", "user.email=probe@example.invalid",
                                                 *a], cwd=repo, check=True, capture_output=True)
                git("init", "-q", "-b", "main")
                write_scene(repo, text, shards)
                git("add", "-A"); git("commit", "-q", "-m", "base")
                first = pack_bytes(repo)
                s, o = base, order
                largest = 0
                for c in range(20):
                    s, o = edit(random.Random(f"{seed}/size/{n}/{c}"), s, o, 5)
                    write_scene(repo, write(s, o), shards)
                    changed = subprocess.run(["git", "status", "--porcelain"], cwd=repo, capture_output=True,
                                             text=True).stdout.split("\n")
                    for line in changed:
                        p = repo / line[3:].strip() if line else None
                        if p and p.is_file():
                            largest = max(largest, p.stat().st_size)
                    git("add", "-A"); git("commit", "-q", "-m", f"edit {c}")
                grown = pack_bytes(repo) - first
            out.append(f"| {n} | {name} | {parsed} | {len(text.encode())} | {len(gzip.compress(text.encode(), 6))} | "
                       f"{first} | {grown} | {largest} | {split_ms:.0f} ms |")
    return out


def selftest() -> int:
    rng = random.Random(7)
    base, order = make_scene(rng, 200)
    for name, (write, read) in FORMS.items():
        if read(write(base, order)) != base:
            print(f"selftest: {name} does not round-trip")
            return 1
    tricky = {"6315684974376e56": {"name": '"a"'}, "1234567890123456": {"node": "6315684974376e56"}}
    for name, (write, read) in FORMS.items():
        if read(write(tricky, list(tricky))) != tricky:
            print(f"selftest: {name} loses an id that reads as a number")
            return 1
    a, _ = edit(random.Random(1), base, order, 10)
    same, conflicts = key_merge(base, a, base)
    if conflicts or same != a:
        print("selftest: merging one side's edits with an untouched side must give that side")
        return 1
    i = order[0]
    x = {k: dict(v) for k, v in base.items()}; x[i]["name"] = '"x"'
    y = {k: dict(v) for k, v in base.items()}; y[i]["name"] = '"y"'
    if key_merge(base, x, y)[1] != [f"{i}.name"]:
        print("selftest: one key changed two ways must be reported as that key")
        return 1
    z = {k: dict(v) for k, v in base.items() if k != i}
    if not key_merge(base, x, z)[1]:
        print("selftest: delete against change must be a conflict")
        return 1
    print(f"selftest: PASS ({len(FORMS)} forms round-trip; key merge: one-sided, same key, delete against change)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--trials", type=int, default=100)
    ap.add_argument("--seed", type=int, default=2026)
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    trials = 12 if args.quick else args.trials
    sizes = [1000, 10000] if args.quick else [1000, 10000, 100000]
    git_version = subprocess.run(["git", "--version"], capture_output=True, text=True).stdout.strip()
    print(f"scene_merge_probe: seed {args.seed}, {git_version}, python {sys.version.split()[0]}\n")
    print("\n".join(merge_table(1000, trials, [5, 20, 80], args.seed)))
    print()
    print("\n".join(size_table(sizes, args.seed)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

# Scene format v2 (design)

Status: design only. Nothing in this document is implemented except the two measuring scripts named in it. It answers
issue #9 (scene format) and states what ludens-core has to provide first (17.97, entities inside `EmbedWorld`).

Where numbers appear they were measured by a script in this repository and the command is given. Where a number is
an estimate, it says so.

## 0. What exists today

- A `.scene` file is rows `path = value` (`editor/scene_text.mojo`), and the rows are ludens-core's
  (`embed/scene_io.mojo`, `scene_to_fields` / `scene_from_fields`). They describe physics only: world settings,
  `body.<i>.*`, `joint.<k>.*`, `material.<k>.*`, and this repo's `sheet.<n>` rows for the event sheet.
- A body is addressed by its position `i`. Every body writes all 44 rows, defaults included, and there is a
  `bodies.count` row. `scene_diff`'s own comment: inserting a body in the middle shows up as the changes of every body
  after it.
- Nothing a player sees is in the file: meshes, colours, render materials, textures, lights, the camera, the
  environment and the post stages are set from code (in ludens-playground `arena/arena.mojo`, `frontier/world.mojo`
  and `app/host.mojo`). The light and camera features of `docs/LIGHTS_CAMERA.md` cannot be written to a scene.
- `export_scene` drops `per_meter` and about twenty solver settings that `embed/transfer.mojo` `settings_hash` counts
  as affecting the result.
- The editor has one command that changes the world (`move_body`); undo keeps whole body records; the event sheet names
  bodies as `@<i>`.

## 1. The model: a scene is a set of (key, value)

A scene means an **unordered set of key / value pairs with unique keys**. A file is one sorted way of writing that set.
Everything else follows from this:

- Merging two people's work is the union of two sets of key changes. Only "one key, two different values" is a
  conflict.
- Editing, undo, prefab overrides, hot reload and live sync are one operation: set a key, or remove a key.
  ludens-core already has it as `SceneChange{path, before, after}`, `scene_diff` and `scene_apply`.

A key is `<entity path>.<component>.<field>`.

| row | meaning |
|---|---|
| `<id>.node = #<parent id>` | the entity exists, and its parent. Reparenting changes this one row. Only the scene root writes `= none` |
| `<id>.name = "crate"` | a display name; not an identity |
| `<id>.<component> = +` | the entity has the component (needed when every field is at its default) |
| `<id>.<component>.<field> = <value>` | written only when it differs from the default |
| `<id>.<component> = -` | in an override only: remove a component the prefab brought |

Left out of the file on purpose, each because it makes two unrelated edits touch the same line:

- **Counts** (`bodies.count`): two people each adding one object always collide.
- **Positional indices**: replaced by stable ids.
- **A list of children on the parent**: the parent is recorded on the child only.
- **Ordered arrays**: every element has its own key, and order is a fractional index inside the key (`a0`, `a0V`,
  `a1`), so two insertions at one place do not rewrite each other's rows.
- **Derived data**: world transforms, content hashes, time stamps.
- **Editor state** (selection, the editor camera, what is expanded): written to an untracked `<scene>.user` file.

## 2. Identity

- **The scene root** is an entity with the fixed id `0000000000000001`. It is in every scene, cannot be removed, and holds
  the scene-wide components (`settings`, `environment`, `sun`, `atmosphere`, `ao`, `pipeline`). It is the only entity
  with `node = none`; a top-level entity has `node = #0000000000000001`. Ids `0000000000000000` to `000000000000ffff`
  are reserved for entities the engine defines; a random id is drawn again if it falls there (decided 2026-11-22).
- **Entity id**: 64 random bits made when the entity is created, written as 16 hex digits. It is not derived from a
  name or a position, so renaming, moving, and two people adding at once do not collide.
- **An entity inside a prefab instance** is named by an id path, `<instance id>/<inner id>`, to any depth.
- **A reference to an entity** is the value `#<id path>` (the two ends of a joint, a camera's target, the subject of an
  event). It replaces `@<i>`.
- **A reference to an asset** is the value `@<asset id>`, and `@<asset id>:clip/Walk` for a part of one. The asset id
  is a stable id kept beside the asset's import settings. The content hash lives in the asset database's lock file,
  one row per asset, not in the scene.
  - Decided 2026-11-22. This differs from issue #9 ("assets by content hash") for one reason: with the hash in the scene, re-importing
    one texture edits every scene that uses it, and two people re-importing conflict. The compiled scene (§6) pins
    hashes.

## 3. Values

One value per row, on one line.

- Reals are written as the **shortest decimal that reads back to the same float32**, in every build, the f64 build of
  ludens-core (`build64`) included: a scene saved from either build has the same bytes, and the extra precision of an
  f64 world exists at run time only (decided 2026-11-22). Today `String(Float64(r))` writes
  `-9.81` as `-9.8100004196167`.
- A vector is one row (`pos = 1 2.5 -3`), not three: two people moving one object is a real conflict.

### 3a. Nine lexical kinds, and no more

| kind | example |
|---|---|
| boolean | `true` |
| numbers, one or several, separated by spaces | `3`, `0 -9.81 0` |
| string | `"floor"` |
| word | `point` |
| entity reference | `#a41b77d3020c9e58` |
| asset reference | `@9c1d22aa5e0b7f31:clip/Walk` |
| empty | `none` |
| to be filled | `?`, `? "which room does this door open to"` |
| presence | `+`, `-` |

A program that knows no component can read, write, diff and merge all nine. The merge tool and an older editor are
therefore unaffected by new types (§8).

### 3b. States without a value

"No value" is six different states. They are not folded into one null.

| state | in the file | in the editor | at build |
|---|---|---|---|
| not written, default applies | no row | shows the default | the default |
| deliberately empty | `= none` | shows "none" | legal if the field is declared optional, an error otherwise |
| to be filled (placeholder) | `= ?`, optionally with a note | marked, with the note | strict: an error listing each one. Development: a warning and a stand-in |
| set, but the target is missing | the original `@id` / `#id` is kept | marked missing, drawn with a stand-in | as above; it reconnects when the target appears, because the id was never cleared |
| set, but of the wrong kind (a mesh in a texture field) | the value is kept | marked | an error |
| a component or field this build does not know | the row is kept as it is | listed as text, not editable | ignored with a warning |

Rules:

- A field declared required, with no default, **is "to be filled" when it has no row**. `?` is for a prefab's author to
  mark a field that has a default as "the scene that uses this prefab fills it".
- **A missing target never clears the reference.** An asset committed later, or on another branch, is the normal case.
- **Stand-ins**: a texture → the built-in checker (the renderer's layer 1 today); a mesh → the unit cube in a marker
  colour; a scene instance → an empty node with its bounds, its override rows kept; an event sheet → no events.
- **A placeholder's type comes from the schema, not from the value.** An empty field has nothing in the file to infer
  a type from, so "a texture goes here" has to be the field's declaration. This is where the need for types comes
  from (§8).

**References across nesting.**

- *Inside* a prefab, entities refer to each other with `#<id>` in the prefab's own id space. Expansion adds the
  instance prefix.
- *Out of* a prefab: a prefab cannot know ids outside itself, so the key is `?` in the prefab and the outer scene
  fills it with an override row, `<instance>/<inner>.sheet.param.target = #<outer id>`. There is no outward path such
  as `#../x`: a prefab would then depend on where it is placed.
- Any key still `?` after full expansion is what a strict build reports, with the whole instance path, so the report
  says which level left it unfilled.

## 4. The file: canonical flat rows

```
ludens-scene 2
0000000000000001.node = none
0000000000000001.settings = +
0000000000000001.settings.gravity = 0 -9.81 0
0000000000000001.environment = +
0000000000000001.environment.kind = sky
0000000000000001.environment.top = 0.22 0.42 0.8
3f9a1c0e77b2d410.node = #0000000000000001
3f9a1c0e77b2d410.name = "floor"
3f9a1c0e77b2d410.transform.pos = 0 -0.5 0
3f9a1c0e77b2d410.body = +
3f9a1c0e77b2d410.body.kind = static
3f9a1c0e77b2d410.collider = +
3f9a1c0e77b2d410.collider.size = 20 0.5 20
3f9a1c0e77b2d410.mesh = +
3f9a1c0e77b2d410.material = +
3f9a1c0e77b2d410.material.kind = triplanar
3f9a1c0e77b2d410.material.texture = @9c1d22aa5e0b7f31
a41b77d3020c9e58.node = #3f9a1c0e77b2d410
a41b77d3020c9e58.transform.pos = 0 4 0
a41b77d3020c9e58.light = +
a41b77d3020c9e58.light.kind = point
a41b77d3020c9e58.light.range = 12
a41b77d3020c9e58.light.shadow = true
```

- Every row carries its whole key. There are no section headers and no indentation, so any set of rows from any
  files is a scene, and the unit that is saved is the unit that is diffed, merged, journalled and overridden.
- Saving always writes the canonical form: rows sorted by the bytes of the key, numbers in their shortest form, LF line
  ends. Saving without a change writes the same bytes.
- Rows the loading build does not know are kept and written back, so an older editor does not delete what a newer one
  wrote.

## 5. Merging

Measured with `pixi run -e wasm scene-merge-probe` (`scripts/scene_merge_probe.py`; seed 2026, git 2.43.0). One scene
of 1000 entities is written in several forms. Two editors start from the same base and each apply N random operations
(70 % set a field, 15 % add an entity, 10 % delete one, 5 % reparent). The three files go through `git merge-file`,
git's own three-way file merge; it agreed with a real two-branch `git merge` in 84 of 84 cross-checked cases. A trial
has a *true* conflict when both changed one key to different values, or one deleted an entity the other changed.

- **false conflict**: git reports a conflict in a trial that has no true conflict.
- **wrong**: git merges cleanly but the result is not the key-wise merge of the two edits.

100 trials per cell; the denominators are the trials without a true conflict.

| form | N = 5: false | wrong | N = 20: false | wrong | N = 80: false | wrong |
|---|---:|---:|---:|---:|---:|---:|
| positional: index, count row, every field (the structure of v1) | 72 / 100 | 2 / 100 | 90 / 90 | 0 / 90 | 28 / 28 | 0 / 28 |
| sections (`[node <id>]` then fields), non-default fields | 1 / 100 | 0 | 6 / 90 | 0 | 25 / 28 | 0 |
| TOML tables, non-default fields | 1 / 100 | 0 | 6 / 90 | 0 | 25 / 28 | 0 |
| flat rows, non-default fields | 1 / 100 | 0 | 7 / 90 | 0 | 25 / 28 | 0 |
| flat rows, an empty line after each row | 1 / 100 | 0 | 6 / 90 | 0 | 25 / 28 | 0 |
| flat rows, every field of a present component written | 0 / 100 | 0 | 4 / 90 | 1 / 90 | 23 / 28 | 0 |
| flat rows, one file per entity | 1 / 100 | 0 | 3 / 90 | 0 | 14 / 28 | 0 |
| flat rows + the key-wise merge driver | 0 / 100 | 0 | 0 / 90 | 0 | 0 / 28 | 0 |

No form merged cleanly in a trial that had a true conflict (0 missed in every cell).

What the numbers say, including where they contradict the first draft of this design:

1. **Positional numbering is the thing to remove.** With five operations each, 72 % of merges that should be clean
   conflict, and 2 % merge "cleanly" into a wrong scene: after one side deletes an entity, the other side's edit lands
   on a different entity's rows. This is v1's structure.
2. **Without a merge tool, flat rows are no better than sections or TOML.** The draft claimed they were. They are
   not: all three give the same rate (89 % at N = 80). The cause is "write only non-default fields": setting a field is
   often an *inserted* line, and two insertions at one place always conflict in a line merge. An empty line between
   rows does not help, and writing every field helps little (82 %) while making the file 2.7 times larger (§6a) and producing one
   wrong clean merge in 90.
3. **One file per entity roughly halves it** (50 % at N = 80): edits to different entities never meet in a file.
4. **The key-wise merge is what removes false conflicts**: 0 in every cell. It is a three-way merge over keys — the
   union of two `scene_diff`s against the base — and reports only keys changed to different values.

Decisions that follow:

- **The merge driver is part of the format, not an option.** `ludens merge <base> <ours> <theirs>`, installed by
  `.gitattributes` (`*.scene merge=ludens-scene`, and the shard files likewise) and one line of git config that
  `ludens new` writes. A repository without it still works; it just conflicts as often as any text format.
- **The source is split into shard files by entity id** (§6, §6a). One file per entity is the layout for a
  repository that cannot run a merge driver; it costs pack size.
- **Flat rows are chosen for a different reason than the draft gave**: the row is the one unit that is saved,
  diffed, merged, journalled, overridden by a prefab instance and sent to a running game. With sections or TOML the
  merge tool, the journal and the override would each need a second representation of the same thing.

After a merge, `ludens check` (also run at load) reports: an entity whose parent does not exist (attached to the root,
with a warning), a reference to an entity or asset that does not exist (named), and an override on an entity the
prefab no longer has (kept as an orphan row).

Limit: GitHub's web merge does not run custom merge drivers, so a pull request that touches a scene another merged
pull request touched shows a conflict there even when the key-wise merge is clean. **A CI job closes that gap**
(decided 2026-11-22): on every pull request that changes a scene file it merges the base branch into the head with
the driver and reports the result as a check, with the keys that really conflict (entity name, key, base / ours /
theirs). A clean result tells the author to merge locally with `ludens merge` (one command, no hand editing); the web
button stays unusable for that case.

## 6. Large scenes: source and compiled forms are different files

- **Source** is one file, or a directory `world.scene/` of shard files. The meaning is the union of the rows of all
  the files. Shards are cut by entity id, not by place in the world: moving an object does not move its rows between
  files, and a save rewrites only the shards that changed. §6a gives the measured sizes behind the shard count.
- **Compiled** is `.lscene`: binary, untracked, made by `ludens build` and the asset database. Prefabs are expanded,
  assets are resolved to content hashes, entities are in canonical order (§10), components are written with
  `ecs/schema.mojo` `write_values`. A large world gets one compiled file per streaming cell, matching
  `gameplay.large_world.WorldPartition`.
- The run time, wasm included, reads compiled bytes only and never parses text. ludens-core measured the text path at
  about two orders of magnitude slower than the snapshot (ROADMAP 17.12: 285 ms to build 1e4 bodies from rows).

### 6a. Size and cost, measured

`pixi run -e wasm scene-merge-probe --sizes-only`. The same scenes as §5 (about nine rows per entity when only
non-default fields are written). "Pack" is the size of `.git/objects` after `git gc`; "growth" is how much it grew over
20 further commits of 5 edits each; "rewritten" is the largest file a commit had to write.

| entities | form | rows | bytes | gzip | pack | growth, 20 commits | rewritten per commit | Python splits all rows in |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 1,000 | positional, every field (v1 structure) | 46,001 | 1,185,361 | 184,388 | 187,246 | 722,388 | 1,191,734 | 14 ms |
| 1,000 | sections, one file | 8,241 | 200,299 | 51,760 | 54,614 | 12,100 | 202,638 | 1 ms |
| 1,000 | flat rows, one file | 8,924 | 333,161 | 77,070 | 79,924 | 12,626 | 337,098 | 2 ms |
| 1,000 | flat rows, 256 shards | 8,924 | 333,161 | 77,070 | 122,563 | 20,863 | 3,236 | 1 ms |
| 1,000 | flat rows, one file per entity | 8,924 | 333,161 | 77,070 | 261,640 | 28,651 | 478 | 2 ms |
| 10,000 | positional, every field (v1 structure) | 460,001 | 12,308,445 | 1,852,585 | 1,855,445 | 9,175,333 | 12,309,871 | 84 ms |
| 10,000 | sections, one file | 82,240 | 1,997,217 | 510,674 | 513,533 | 14,262 | 1,998,525 | 19 ms |
| 10,000 | flat rows, one file | 89,297 | 3,328,786 | 765,181 | 768,037 | 15,514 | 3,330,952 | 27 ms |
| 10,000 | flat rows, 256 shards | 89,297 | 3,328,786 | 765,181 | 833,727 | 20,865 | 18,575 | 14 ms |
| 10,000 | flat rows, every field written, one file | 241,346 | 9,111,214 | 1,321,322 | 1,324,176 | 23,646 | 9,112,128 | 67 ms |
| 10,000 | flat rows, one file per entity | 89,297 | 3,328,786 | 765,181 | 2,376,738 | 27,585 | 476 | 25 ms |
| 100,000 | positional, every field (v1 structure) | 4,600,001 | 127,690,761 | 18,631,325 | 18,634,182 | 85,345,840 | 127,698,927 | 892 ms |
| 100,000 | sections, one file | 823,769 | 19,997,774 | 5,063,530 | 5,066,386 | 23,616 | 20,000,165 | 134 ms |
| 100,000 | flat rows, one file | 893,903 | 33,325,338 | 7,595,439 | 7,598,297 | 31,807 | 33,329,373 | 166 ms |
| 100,000 | flat rows, 256 shards | 893,903 | 33,325,338 | 7,595,439 | 7,702,182 | 19,916 | 145,254 | 257 ms |

One file per entity was not run at 100,000 (that many files in one repository is a separate measurement).

What the numbers say:

- **A flat-row scene is about 333 bytes per entity** (33 MB at 100,000), 77 bytes gzipped. The first draft estimated
  500. It is 1.67 times the sections form on disk and 1.5 times in the git pack: the repeated id prefix costs that
  much after compression, not nothing as the draft assumed.
- **v1's structure costs 3.6 times the rows of §4 on disk, and its history is the real problem**: 20 small commits
  add 85 MB to the pack at 100,000 entities, against 0.02 to 0.03 MB for any id-keyed form. A delete shifts every
  later index, so every later line changes.
- **History is cheap for every id-keyed form**: 12 to 32 KB for 20 commits, almost independent of scene size.
- **Shards trade pack size for write size.** 256 shards add 1 to 9 % to the pack at 10,000 entities and above, and a
  save rewrites 18 KB (at 10,000) or 145 KB (at 100,000) where one file rewrites 3.3 MB or 33 MB. One file per entity
  rewrites under 500 bytes but triples the pack at 10,000 entities (2.4 MB against 0.77 MB), because git compresses
  small files one by one.
- **Parsing is not a concern at editor scale**: Python splits 894,000 rows in 166 ms. This is the split only, not
  building a world; ludens-core's measured 285 ms for 1e4 bodies from rows (17.12) is the cost of that second part.

**The source layout, decided from these and from §5 (2026-11-22):** 256 shard files, named by the first two hex
digits of the entity id (`00.rows` to `ff.rows`), fixed for every scene size. A shard never changes its name, so no
save moves rows between files. Measured above: at 100,000 entities a save rewrites 145 KB, and the shards add 1 to
9 % to the pack against one file. A small scene with fewer entities than shards simply has fewer files (an empty
shard is not written). One file per entity is offered for a repository that cannot install the merge driver: it
halves false conflicts there (§5) at three times the pack.

Kept out of the row count by design, not by the layout: a prefab instance is two rows plus its overrides, and
procedural content is a `generator` entity, not its output (the playground's 256 cells of scenery are a few generator
entities, not 2,560 entities of rows).

Costs accepted knowingly:

- A text source is larger than a binary one and slower to open than a snapshot. It buys merging.
- Random ids make a raw diff unreadable. `ludens diff` has to show changes by name and hierarchy.

## 7. Reuse: a scene is a prefab

- Any scene can be instanced: `<id>.node = #<parent>` and `<id>.instance = @<scene asset>`.
- Expansion: read the referenced scene's rows, prefix every key with `<id>/`, then lay the outer scene's rows that
  start with `<id>/` over them. An override is an ordinary row, with no second syntax:
  - change a property: `<id>/<inner>.light.intensity = 5`
  - add or remove a component: `<id>/<inner>.<component> = +` / `= -`
  - remove an inner entity: `<id>/<inner>.node = -`. `-` means "remove" everywhere (an entity, a component); `none`
    appears only on the scene root, so the two are never the same row (decided 2026-11-22)
  - add a child: an ordinary entity whose parent is `<id>/<inner>`
- A variant is a scene whose root is an instance of another scene. Nesting has no depth limit. A cycle is an error at
  expansion that prints the path.
- In the editor, "apply to prefab" moves override rows into the prefab's file and "revert" deletes them.
- An override that targets an entity the prefab no longer has is kept as an orphan row and reported; it is not
  deleted for the user, so a removal on another branch or one that is undone later loses nothing. `ludens check
  --prune-orphans` lists them and deletes them on request (decided 2026-11-22).

## 8. Types: the file grammar is closed, the schema is open

The need for types keeps growing (curves, gradients, bit masks, angles with units, optional references, references
limited to one kind of asset, event sheet parameters, a game's own data). The design puts all of that growth in one
of two layers.

**The file layer** is the nine lexical kinds of §3a. It does not grow.

**The schema layer** expresses a new type by composition:

| need | how it is written |
|---|---|
| a struct | one more segment in the field path: `camera.lens.fstop` |
| a list, an ordered set | one row per element, keyed by a fractional index: `curve.pt.a0 = 0 1 0` |
| a map, a set | one row per element, keyed by the user's key |
| optional | `none` |
| an enumeration | a word; the schema lists the words, an unknown word is kept and reported |
| one of several (a light's kind, a collider's shape, an event parameter's type) | a `kind` word and that kind's fields. Changing the kind deletes the old kind's rows in the same transaction, so undo restores them |
| a reference limited to a kind | a constraint in the schema ("asset, of kind texture", "entity, with a body"). In the file it is still `@id` / `#id` |
| a range, a unit, how it is shown (an angle, a colour space, slider bounds) | attributes of the schema, not types. The file always holds SI units and radians |
| a curve, a gradient | a list of key points |
| bulk binary data (a height field, a mesh, a navmesh, a bake) | never rows. It is an asset referenced by `@id`; scene-private data sits under the scene directory's `blobs/` |

**Three sources of schema**, behind one interface for validation:

1. Compile-time reflection of a struct (`ecs/schema.mojo` walks fields with `reflect[T]` and produces dotted
   paths): the engine's and a game's components.
2. A declaration inside a referenced asset: an event sheet's parameters, a generator's parameters, a behaviour
   script's exposed attributes.
3. None (a row this build does not know): lexical check only, kept as it is.

Because source 2 depends on an asset, validation has two stages: lexical, which needs no schema, and semantic, which
waits for assets. When the event sheet itself is a placeholder or missing, its parameter rows cannot be checked; they
are marked unchecked and kept.

What ludens-core has to add once: `ecs/schema.mojo` handles plain numeric fields today (`get_f64` / `set_f64`; no
`String`, no `List`). It needs field kinds (boolean, integer, real, vector, enumeration, entity reference, asset
reference, string, list, one-of), the optional / required marks, and the kind constraint on references. After that a
new type is a new registered struct or a new word, with no change to the schema machinery or the grammar.

**What this does not cover**:

- A value that needs a tenth lexical kind. None is known. It would raise the grammar version, and older tools would
  see an invalid row.
- A field that changes type between versions (a real becomes a vector). That needs an upgrade function (§9); matching
  by field name cannot do it.
- Source 2 follows the asset's content: when an event sheet changes a parameter's type, old values in scenes that use
  it become "wrong kind". They are marked and kept, not converted.

### 8a. Components of the first version

Fields are the parameters the code takes today.

| component | holds | today |
|---|---|---|
| `settings` (scene root) | dt, gravity, per_meter, and every solver setting `settings_hash` counts | partly dropped by `export_scene` |
| `transform` | pos, rot, scale, relative to the parent | — |
| `body` | kind (static / dynamic / kinematic), mass, vel, omega, the 21 properties of `BodyProps` | `SceneBody` |
| `collider` | shape (box / sphere / capsule / hull / mesh / heightfield), size, asset, category, mask, physics material | `SceneBody` |
| `joint` | kind, a, b (entity references), anchors, axes, limit / motor / spring / break | `SceneJoint` |
| `mesh` | shape (box / sphere) or an asset; casts a shadow | `DrawItem.kind`, `mesh_id` |
| `material` | kind (color / uv / triplanar / sky / pbr), color, texture, roughness, metallic | `MAT_*`, `layer` |
| `skin` | skeleton asset, clip | `pose_id` |
| `light` | kind (point / spot / dir / area) and that kind's fields, shadow | `PointLight`, `SpotLight`, `DirLight`, `AreaLight` |
| `sun`, `environment`, `atmosphere`, `ao` (scene root) | the sun; the environment (uniform / sky / equirect / probe); fog and exposure; the AO region | `set_sun`, `set_environment`, `set_atmosphere`, `set_ao` |
| `camera` | perspective or orthographic, fov or half height, near, far, focus, f-stop, sensor, shutter | `CameraPose`, `View`, `lens_*` |
| `pipeline` (scene root) | the name of a pipeline and its parameters | see below |
| `event` | `when` / `do` lines in fractional-index order, subjects as `#id` | `sheet.<n>` |
| `bind` | a field driven by another source (§12) | — |
| `group` | group names | 17.97 |
| `generator` | a generator, a seed, parameters; expands to child entities at build | playground `_cell` |
| `script` | a behaviour script and its exposed keys (§13) | — |
| `rope`, `cloth`, `fracture`, `character`, `nav_region`, `trigger` | their parameters | hard-coded in the playground |
| `editor` | locked, hidden, folder colour; stripped at compile | — |

A limit to state plainly: a render pipeline is a compile-time type (`SceneRendererOf[P, F, A]`,
`docs/PIPELINES.md`). A scene can name one of the pipelines compiled into the program and set its parameters. It
cannot assemble a new pipeline from data.

## 9. Versions and upgrades

- The first line, `ludens-scene 2`, is the grammar version.
- Each component has a version. The file writes `version.<component> = N` only when N is above 1. An upgrade is a
  registered function from rows to rows, run in order at load.
- **Changing a default is a version change.** "Write only what differs from the default" would otherwise change old
  scenes silently when a default moves. The upgrade function writes the old default into old files as a row.
- v1 to v2: `body.<i>` becomes an entity whose id is derived from `i` (one v1 file always gives the same ids),
  `@<i>` becomes `#id`, and the count rows are dropped.

## 10. Determinism

- The order in which bodies enter the physics world changes the simulation and the world hash. The canonical build
  order is "sorted by entity id, a parent before its children". It does not depend on who merged what, in which
  order.
- In the editor the document is the truth and the world is derived from it. Play builds the world from the document
  in canonical order and does not reuse the world edited so far, so "save, then load" and "press Play" give the same
  hash.

## 11. How the editor works with it

| action | how |
|---|---|
| in memory | The scene is **not** kept as text rows. Data lives in typed ECS components; rows are produced for one entity when needed (save, diff, merge, journal). Only unknown rows are kept as text. The map from a field path to (component, offset) is computed once at registration |
| an edit | A transaction is a list of changes, each (entity, field, before, after) in binary, equivalent to a `SceneChange`. The inspector is generated from `TypeSchema`; a `TypeDrawer` supplies a custom look by type name |
| applying to the world | One apply function per component, given only the changed fields. For a body this is today's logic: `write_body_record` when the shape is unchanged, otherwise remove and `restore_body` |
| undo / redo | The same changes applied in reverse. This replaces whole body records, and brings the event sheet, lights and the camera into the same history |
| commands | Generic: `set <id> <component.field> <value>`, `add_node`, `remove`, `reparent`, `add_component`, `remove_component`, `instance <asset>`, `apply_override`, `revert_override`. `move_body` becomes an alias of `set … transform.pos` |
| save | Rewrites only the shards that changed, in canonical form |
| play | Builds the world from the document, runs, and discards it at stop |
| build | `ludens build` writes `.lscene`; the asset database decides by the hash of the source rows whether to rebuild |

### 11a. Reload, consistency while editing, recovery

One mechanism for all of it: **a validated set of changes, applied as a whole at a tick boundary, and undone as a whole
by its inverse on failure.** `editor/reload.mojo`'s rule stays: build the new state first; on failure the old one is
untouched and the error is logged.

| what changed | handling |
|---|---|
| the scene file on disk (git pull, a branch switch, another tool) | Diff the file's rows against the rows the entities in memory produce and apply the difference. With no unsaved edits: apply it as one undo step. With unsaved edits: a three-way merge with the last saved content as the base; keys that collide go to the conflict list and the user's edits are not overwritten |
| the scene, while the game runs (live edit) | The changes go to the running world in the same form and are applied at the next tick boundary. A property is written in place; a change of shape or mass removes the body and restores it in the same slot. Run-time state (a body that has moved) is overwritten only for the keys that changed. Each change is recorded in the replay with its tick, so a replay applies it at the same tick |
| code (17.91 module swap) | The world moves in the transfer blob. When a component's struct changed, `schema.read_values` matches by field name and returns a `ReadReport` of what was restored, dropped, mismatched and defaulted. This exists |
| an asset | The scene refers to the asset by id, so the scene file does not change. The asset database rebuilds it and the renderer takes the new one; on a failed import `keep_on_failure` keeps the last good artifact |

Recovery:

- **Crash**: every committed transaction is appended to an untracked `<scene>.journal`, whose header holds the hash
  of the saved content it applies to. It is emptied after a successful save. At start, a journal whose hash matches
  can be replayed; one that does not match is kept and reported, never applied by itself.
- **An interrupted save**: each shard is written to a temporary file and renamed. The journal is emptied only after
  every rename, so a crash in between is recoverable from "old shards + journal".
- **The end of Play**: the world Play used was built from the document and is discarded. The document was never
  touched, so there is no restore step.
- **A merge conflict**: the merge tool writes no conflict markers into the scene. The file keeps our value and still
  loads; the conflicting keys, each with its base, ours and theirs values, go to `<scene>.conflicts`, the editor lists
  them for a choice per key, and the file is deleted when none is left.
- **A damaged file**: rows are parsed one by one and an error names its line. A last row cut short (no line end) is
  an error, not a row. There is no checksum row: it would change on every save and collide on every merge, and git
  already verifies its objects.
- **A newer file in an older program**: unknown rows are kept and written back.

## 12. Reactive behaviour: three layers, three decisions

What ludens-core already has: `ecs/reactive_backend.mojo` delivers an `ObsEvent` (`EV_ADD`, `EV_SET`, `EV_REMOVE`)
to each registered observer at the mutation site (`observe1` / `observe2`), in mutation order, bit-identical on
replay; `ecs/world.mojo` has change detection (`track_changes`, `changed[C](since)`). The cost is measured in
ludens-core's `BENCHMARK_REPORT.md`: about 85 to 90 ns per update on the reactive backend, 47 ns on the sparse set,
about 1 ns on the archetype SoA.

**Layer 1, propagation of changes: adopted, as the structure of the editor and the run time.** Every edit is a key
change, so everything downstream subscribes to changes and neither polls nor rebuilds the whole scene.

| subscriber | reacts to | does |
|---|---|---|
| physics apply | `body`, `collider`, `joint` | writes or rebuilds that body |
| draw extraction | `transform`, `mesh`, `material`, `skin` | updates that entity's `DrawItem` |
| lights and environment | `light`, `sun`, `environment`, `atmosphere` | calls the matching `set_*`, re-packs the shadow atlas |
| bakes | a change to static geometry | marks the navmesh, AO and environment probe stale; recomputed later |
| prefab instances | a change to the referenced scene | re-expands, diffs against the old expansion, sends only the difference |
| journal, undo, live sync | every change | records or forwards |
| inspector | nothing | the editor UI is immediate mode (`Panel.draw` reads the state each frame) |

Rules, for determinism and against re-entry:

- Changes are sent as a batch at commit and applied at a tick boundary. No callback runs while a mutation is in
  progress.
- A batch is processed in key order, so the result does not depend on the order of the edits or on the machine.
- The grain is (entity, component). There is no per-field callback.
- The simulation's inner loops do not use the reactive backend (a write costs 40 to 80 times the SoA write). The
  editor and the scene layer use change detection or observers.

**Layer 2, data binding: adopted within limits, with no new grammar.** "This field follows that source" is rows of a
`bind` component:

```
a41b77d3020c9e58.bind.a0.to = "light.intensity"
a41b77d3020c9e58.bind.a0.from = #7c0e51b2a9d4f633
a41b77d3020c9e58.bind.a0.field = "health.ratio"
a41b77d3020c9e58.bind.a0.map = linear
a41b77d3020c9e58.bind.a0.scale = 5
```

- A source is another entity's field, an event sheet variable, a cvar, or a curve asset over time.
- A mapping is one of a few built-in pure functions: copy, linear, clamp, curve lookup.
- The bound field may still have a static row, used as the initial value and shown in the editor. In a merge it is an
  ordinary row.
- Bindings are evaluated at one fixed point of every tick in dependency order. A cycle is an error at load.

**Not adopted: an expression in a row**, such as `light.intensity = health.ratio * 5 + sin(t)`. It needs an expression
language with its own type checking, a value would stop being one of nine lexical kinds, and its floating-point
result would need its own native / wasm guarantee. Anything beyond the built-in mappings belongs to an event sheet or
a behaviour script.

**Layer 3, reaction to events: exists.** The event sheet's `when … do …` is that layer. The format changes its
subjects from `@<i>` to `#id` and makes an event a component of an entity.

## 13. Where Python fits

**The scene file is data, not a Python program.** By the four criteria this design was asked to weigh:

| criterion | a Python program as the scene |
|---|---|
| people working in parallel, git conflicts | code cannot be merged by key; two edits to one loop are a text conflict |
| editing | the editor would have to write source back. In a `for` loop that makes 100 crates there is nowhere to write "move the 37th". Restricted to a declarative subset the editor can write back, it is a data file with a different grammar |
| loading | loading a scene is running a program: every platform's run time carries Python, and opening someone's scene runs their code |
| expressiveness | the one gain: loops, functions, parameterised generation |

Bevy is the nearby case: `bsn!` is written in code, and the project is still building a separate `.bsn` asset format
for its editor to edit.

Python is used where code fits, and the data format does not change:

1. **Generators.** `generator.source = @<script>.py` runs at **build time** under native CPython and emits rows that
   are compiled into `.lscene`. The run time needs no Python, so this works for the web build. A generator may depend
   on its seed and parameters only. The playground's `_cell` is this kind of code.
2. **A Python API for scenes.** A `ludens.scene` module reads and writes rows: batch edits, importers, upgrades,
   scenes for tests. A scene being a set of keys, this layer is thin.
3. **Behaviour scripts.** `script.source = @<script>.py`; the keys it exposes are declared by type annotations and
   become schema source 2 (§8), so placeholders and overrides apply to them as to any field. Natively this is
   ludens-core's existing binding (17.21). For the browser, see the measurement below.

### 13a. Measured: Python in the browser beside the engine

`pixi run -e wasm python-web-probe` (`scripts/python_web_probe.py`, `.mjs`). The engine is one wasm64 module; CPython
for the web (Pyodide 314.0.8, Python 3.14.2) is a wasm32 module, so they cannot be linked. The probe loads both in one
JS realm and Python calls the engine's C-ABI exports through a JS object. The same script source runs natively under
CPython 3.14.10 with ctypes against the same C-ABI built from the same pinned ludens-core (`6aac9401`). Hosts: node
24.22 and headless Chrome 153. Ranges are over three runs on one machine.

| | native CPython + ctypes | Pyodide in node | Pyodide in Chrome |
|---|---:|---:|---:|
| world hash after 600 ticks, script applies an impulse each tick | `1b6a50030efc1b08` | equal | equal |
| the same, the script using `math.sin` / `math.cos` | `89aa5c7be8c4e2c8` | equal | equal |
| one behaviour call (host → Python → one engine call) | 0.87 – 1.16 µs | 3.9 – 4.3 µs | 2.7 – 3.5 µs |
| Python → engine, one call | 175 – 332 ns | 233 – 472 ns | 332 – 870 ns |
| behaviour calls that fit in 1 % of a 60 Hz tick | 143 – 191 | 38 – 43 | 47 – 61 |
| load of the Python run time | — | 2.2 – 2.3 s | 2.5 – 2.8 s |
| start to first world hash | — | 2.4 – 2.5 s | 2.7 – 3.0 s |

Download: Pyodide's five run-time files are 13,530,536 bytes (6,343,086 with gzip -6), of which `pyodide.asm.wasm` is
9,597,892 and the standard library 2,545,550. The engine's C-ABI module is 1,016,231 bytes (307,284 gzipped).

`math.*` on 20,000 inputs, Pyodide against native CPython, as float64: `sin` differs in 596 results, `cos` 606, `tan`
746, `atan2` 824, `pow` 17, `exp` 8, `log` 1, `sqrt` 0, each by one unit in the last place. Chrome's results equal
node's. Rounded to float32, which is what the C-ABI's arguments are, none of the 160,000 differ.

What this supports, and what it does not:

- **It works.** A Python script drives the wasm64 engine in a browser and the world hash equals the native one.
- **The equal hash with `math.sin` is not a guarantee.** The two interpreters use different libm builds and do
  disagree in the last bit of a float64; here every difference vanished when the value was narrowed to float32. A
  script that accumulates in float64 across ticks, or compares two close values, can diverge. Scripts that must be
  deterministic across hosts need the engine's own math functions, as the engine's Mojo code already uses for
  native / wasm parity.
- **The criterion written before the run was not met by any host.** It asked for 1000 behaviour calls within 1 % of a
  tick (167 ns each). Native CPython takes 0.87 – 1.16 µs per call. The criterion was wrong for per-entity calls in
  any Python; the usable shape is one call per system per tick that works on a batch, where 40 to 190 calls fit.
- **The download is the real cost on the web**: 6.3 MB gzipped against the engine's 0.3 MB, and 2.5 to 3 s before the
  first tick.
- Not measured: Safari (no memory64, so the engine module itself does not run there), mobile browsers, memory use,
  and a script that allocates per tick.

Decision for the format: `script` is a component whose source is an asset, and the format does not depend on the
language. Which languages a behaviour script may be written in, and how the same script is made bit-identical on every
host, is the subject of a separate study of the scripting layer; this document does not settle it.

## 14. Who provides what

- **ludens-core (17.97, first)**: an ECS world and `ChildOf` inside `EmbedWorld`; every rigid body an entity; a
  64-bit stable id component; groups; generic component ↔ rows through schema reflection, with the field kinds of §8;
  the shortest float32 writer; all result-affecting settings exported; the canonical build order.
- **ludens-engine (#9)**: the file grammar and canonical writer, id generation, prefab expansion, asset reference
  resolution, the merge driver, shard directories, `.lscene` compilation, the render components and the system that
  turns entities into `DrawItem`s, lights and a `View`, the editor's commands and panels.

## 15. What was taken from other engines, and what was not

| from | taken | not taken, and why |
|---|---|---|
| Unity | stable ids; an override as target + property path + value; a merge tool; asset id separate from content | children listed on the parent; one multi-line document per object |
| Unreal | source and cooked forms are different files; one file per actor so that two people do not write one file | a binary source and exclusive locks |
| Godot | a scene is a prefab; only non-default values are stored; the parent is recorded on the child | sections (a line's meaning depends on the header above it) |
| Bevy | a scene is a patch and layers override; components are registered by reflection | code as the stored form (§13) |
| Cocos Creator | an override's target is an id path | objects referring to each other by array index |

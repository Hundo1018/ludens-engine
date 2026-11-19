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
  environment and the post stages are set from code (`game/arena.mojo`, and in ludens-playground `frontier/world.mojo`
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
| `<id>.node = <parent id>` or `= -` | the entity exists, and its parent (`-`: the scene root). Reparenting changes this one row |
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

- **Entity id**: 64 random bits made when the entity is created, written as 16 hex digits. It is not derived from a
  name or a position, so renaming, moving, and two people adding at once do not collide.
- **An entity inside a prefab instance** is named by an id path, `<instance id>/<inner id>`, to any depth.
- **A reference to an entity** is the value `#<id path>` (the two ends of a joint, a camera's target, the subject of an
  event). It replaces `@<i>`.
- **A reference to an asset** is the value `@<asset id>`, and `@<asset id>:clip/Walk` for a part of one. The asset id
  is a stable id kept beside the asset's import settings. The content hash lives in the asset database's lock file,
  one row per asset, not in the scene.
  - This differs from issue #9 ("assets by content hash") for one reason: with the hash in the scene, re-importing
    one texture edits every scene that uses it, and two people re-importing conflict. The compiled scene (§6) pins
    hashes.

## 3. Values

One value per row, on one line.

- Reals are written as the **shortest decimal that reads back to the same float32**. Today `String(Float64(r))` writes
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
0000000000000001.node = -
0000000000000001.settings = +
0000000000000001.settings.gravity = 0 -9.81 0
0000000000000001.environment = +
0000000000000001.environment.kind = sky
0000000000000001.environment.top = 0.22 0.42 0.8
3f9a1c0e77b2d410.node = -
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
a41b77d3020c9e58.node = 3f9a1c0e77b2d410
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

@@MERGE@@

## 6. Large scenes: source and compiled forms are different files

- **Source** is one file, or a directory `world.scene/` of shard files. The meaning is the union of the rows of all
  the files. Shards are cut by entity id, not by place in the world: moving an object does not move its rows between
  files, and a save rewrites only the shards that changed. §5 gives the measured reason the default shard is one
  entity.
- **Compiled** is `.lscene`: binary, untracked, made by `ludens build` and the asset database. Prefabs are expanded,
  assets are resolved to content hashes, entities are in canonical order (§10), components are written with
  `ecs/schema.mojo` `write_values`. A large world gets one compiled file per streaming cell, matching
  `gameplay.large_world.WorldPartition`.
- The run time, wasm included, reads compiled bytes only and never parses text. ludens-core measured the text path at
  about two orders of magnitude slower than the snapshot (ROADMAP 17.12: 285 ms to build 1e4 bodies from rows).

@@SIZE@@

## 7. Reuse: a scene is a prefab

- Any scene can be instanced: `<id>.node = <parent>` and `<id>.instance = @<scene asset>`.
- Expansion: read the referenced scene's rows, prefix every key with `<id>/`, then lay the outer scene's rows that
  start with `<id>/` over them. An override is an ordinary row, with no second syntax:
  - change a property: `<id>/<inner>.light.intensity = 5`
  - add or remove a component: `<id>/<inner>.<component> = +` / `= -`
  - remove an inner entity: `<id>/<inner>.node = -`
  - add a child: an ordinary entity whose parent is `<id>/<inner>`
- A variant is a scene whose root is an instance of another scene. Nesting has no depth limit. A cycle is an error at
  expansion that prints the path.
- In the editor, "apply to prefab" moves override rows into the prefab's file and "revert" deletes them.
- An override that targets an entity the prefab no longer has is kept as an orphan row and reported; it is not
  deleted for the user.

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

A limit to state plainly: a render pipeline is a compile-time type (`ArenaRendererOf[P, F, A]`,
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

@@PYTHON@@

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

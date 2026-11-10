"""Hot reload of a scene (ludens-engine #14): replace the world with a changed scene file without restarting.

`reload_scene(ed, text)` builds the new world from the scene text first. If that fails (a malformed row, a bad
value, a missing field) nothing changes: the old world keeps running, the error is appended to `ed.messages` for the
log panel, and the error is raised for the caller. If it works, the new world is stepped to the tick the old one
was at, so the result is exactly the world a restart with the new file run to that tick would give, then it replaces
the old one. The undo history is cleared (it refers to bodies of the old scene) and the selection keeps only
handles that are alive in the new world. A reload is refused while playing: stop first.

Assets and code reload use the same boundary rule (the swap happens between ticks): assets through the asset
database's rebuild log (`editor.assets`), code through `embed.transfer` (ludens-core 17.91)."""
from editor.scene_text import scene_rows_from_text
from editor.state import Editor
from embed.scene_io import import_scene, scene_from_fields
from embed.world import EmbedWorld


def world_from_text(text: String) raises -> EmbedWorld:
    var doc = scene_from_fields(scene_rows_from_text(text))
    var w = EmbedWorld(doc.dt, doc.gravity)
    import_scene(w, doc)
    return w^


def reload_scene(mut ed: Editor, text: String) raises:
    if ed.playing:
        raise Error("reload: stop playing first")
    if ed.log.depth > 0:
        raise Error("reload: a transaction is open")
    var w: EmbedWorld
    try:
        w = world_from_text(text)
        for _ in range(ed.world.tick):
            for _ in range(w.ticks_due(1.0 / 60.0)):
                w.physics_tick()
    except e:
        ed.messages.append("reload failed: " + String(e))
        raise Error("reload failed: " + String(e))
    ed.world = w^
    ed.reset_history()
    ed.prune_selection()
    ed.messages.append("reloaded the scene at tick " + String(ed.world.tick))

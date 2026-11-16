"""Visual-test modes for ArenaRenderer (ludens-engine#80): a capture can count what the renderer knows and a picture cannot
tell apart.

  DEBUG_FLAT  every colour-only item (material 0) is drawn magenta: the share of magenta pixels is the share of the frame
              drawn without a texture.
  DEBUG_SKY   the sky (material 3) is drawn as a colour-only magenta item, and the renderer turns fog and the linear
              workflow off for the frame: a sky pixel is then told from far ground that fog has faded to the horizon
              colour.

`debug_recolor` changes the items only; ArenaRenderer.draw calls it after the frame's items are pushed and, for
DEBUG_SKY, overrides the atmosphere's fog and linear flags.
"""
from geometry.vec import Real, Vec3
from game.arena import DrawItem

comptime DEBUG_NONE = 0
comptime DEBUG_FLAT = 1
comptime DEBUG_SKY = 2
comptime MARK = Vec3(Real(1.0), Real(0.0), Real(1.0), Real(0.0))


def debug_recolor(mut items: List[DrawItem], view: Int):
    if view == DEBUG_FLAT:
        for i in range(len(items)):
            if items[i].material == 0:
                items[i].color = MARK
    elif view == DEBUG_SKY:
        for i in range(len(items)):
            if items[i].material == 3:
                items[i].color = MARK
                items[i].material = 0

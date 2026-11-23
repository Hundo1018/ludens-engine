"""The demo game's string tables (ludens-engine #116): English (the source locale) and Traditional Chinese, with a context
note and a maximum length for every key. `demo_localizer()` is the table list `DemoMode` indexes with `UiEnv.locale`:
0 = en, 1 = zh-TW."""
from ui.loc import Localizer, PLURAL_ONE_OTHER, PLURAL_OTHER, StringTable


def demo_localizer() -> Localizer:
    var loc = Localizer()
    var en = StringTable("en", PLURAL_ONE_OTHER)
    en.add_plural("hud.jumps", "{n} jumps", one="{n} jump", context="Counter in the top-left corner; {n} is how many times the ball has jumped", max_len=14)
    en.add("hud.hint", "WASD move   Space jump   Drag mouse to look   P pause   R restart", "Controls hint along the bottom edge of the screen", 80)
    en.add("hud.paused", "PAUSED", "Banner in the middle of the screen while the game is paused", 10)
    var zh = StringTable("zh-TW", PLURAL_OTHER, "en")
    zh.add_plural("hud.jumps", "跳躍 {n} 次", max_len=14)
    zh.add("hud.hint", "WASD 移動　空白鍵 跳躍　拖曳滑鼠 轉向　P 暫停　R 重新開始", max_len=80)
    zh.add("hud.paused", "暫停", max_len=10)
    loc.add_table(en^)
    loc.add_table(zh^)
    return loc^

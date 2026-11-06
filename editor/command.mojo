"""Editor command layer (ludens-shell #6, E1; registration #18).

Every editing operation is a command: a name plus text arguments. Text is the one canonical form. The CLI
passes argv as it is and the GUI formats its typed values to text, so both reach the same parser and the same
code, and a GUI action can be replayed from a script.

A command that changes the world records its inverse so it can be undone. The record kept here is the
previous pose of one body; engine 17.43 (ludens-engine #83) has the transaction layer that replaces the
per-command record.

Commands are registered through `editor.ext`; `Standard` is the registry of this repository's built-ins. A build that
links plugins declares its own `Registry[...]` listing them after the built-ins."""
from editor.builtin import MoveBody
from editor.ext import Registry
from editor.state import Editor, Inverse

comptime Standard = Registry[MoveBody]

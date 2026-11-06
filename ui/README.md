# ui/

Shared UI toolkit for the game and the editor (ludens-shell #17). Empty until that issue lands.

Rules (checked by `scripts/check_layout.py`):

- Mojo and Markdown only.
- Imports the standard library, `wgpu` and `ui` itself. Never engine packages, `app/` or `editor/`,
  so the directory can become a standalone library without changes.

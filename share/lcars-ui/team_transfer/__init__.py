"""Team transfer / migration audit subsystem.

Two CLIs (run from the repo root with lcars-ui/ on sys.path):
  PYTHONPATH=lcars-ui python -m team_transfer.generator  --output migration-manifest.json
  PYTHONPATH=lcars-ui python3 -m team_transfer.verifier  --manifest migration-manifest.json

The verifier uses ONLY Python stdlib so it runs on a destination Mac before .venv is rebuilt.

Package location note (Option A):
  This package lives inside lcars-ui/ whose directory name contains a hyphen, making it
  an invalid Python package name. Callers must add the lcars-ui/ directory to sys.path:
    sys.path.insert(0, '/path/to/dev-team/lcars-ui')
  After that, imports work as:
    from team_transfer.channels import build_config
  This matches the pattern already used by server.py and sibling modules in lcars-ui/.
  Renaming lcars-ui/ to lcars_ui/ would break every existing reference (server start
  scripts, LCARS supervisor, hooks) — not worth it.
"""

SCHEMA_VERSION = 2

# Publishing EchoPilot Publicly

This repository is intended to be published without personal assistant, user, customer, or private-workflow references.

## Do not make the old private repository public directly

GitHub exposes the full Git history when a repository is made public. If the private development history contained personal names, internal project notes, customer names, or assistant-specific workflow references, those remain visible even when the current working tree is clean.

Recommended approach:

1. Keep the old/private development repository private.
2. Create a new public repository, e.g. `echopilot`.
3. Copy only the sanitized working tree into the new repository.
4. Create a fresh initial commit.
5. Push that clean history to the public repository.

Example:

```bash
mkdir /tmp/echopilot-public
rsync -a --delete \
  --exclude .git \
  --exclude .build \
  --exclude .venv-transcribe \
  --exclude build \
  /path/to/private/echopilot/ /tmp/echopilot-public/
cd /tmp/echopilot-public
git init
git add .
git commit -m "Initial public release"
git remote add origin git@github.com:<owner>/echopilot.git
git push -u origin main
```

## Pre-publication checklist

Run from the repository root:

```bash
git grep -n -i -E '<private-name>|<customer-name>|<internal-domain>|<local-path>' || true
bash -n scripts/*.sh
python3 -m py_compile scripts/build-timeline.py
```

On macOS, also run:

```bash
scripts/install-echopilot-app.sh
open /Applications/EchoPilot.app
```

## Bundle identifier

The public placeholder bundle identifier is:

```text
com.echopilot.app
```

For a real signed/notarized product release, replace it with a bundle identifier controlled by the publisher, then rebuild and re-grant macOS privacy permissions as needed.

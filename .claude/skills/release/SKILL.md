---
name: release
description: Cut a TinyTweaks release — pick the version, move Unreleased changelog entries under it, bump the TOC version, run the full gate, build the zip, commit and tag. Pushing and uploading happen only after the user confirms. Use when the user asks to release, tag or package a version.
argument-hint: "[version, e.g. 0.2.0; default: derived from the changelog]"
disable-model-invocation: true
---

# release

Version requested: **$ARGUMENTS**

## 1. Preconditions

- On `main`, working tree clean (`git status --porcelain` empty), up to date with
  `origin/main`.
- `make check` is green.
- `CHANGELOG.md` has entries under *Unreleased*. If it's empty, stop: there's nothing to
  release.
- Every change in *Unreleased* has passed `/ingame-verify`. If not, ask the user whether
  to release anyway and say what is unverified.

## 2. Version

Semantic versioning on what the player sees: patch for fixes, minor for new features or
settings, major for a change that drops or reinterprets saved settings. If an argument
was given, use it; otherwise propose one from the changelog and use it.

## 3. Prepare the commit

1. `CHANGELOG.md`: rename *Unreleased* to `## <version> — <YYYY-MM-DD>` and add a new empty
   *Unreleased* section above it.
2. `TinyTweaks.toc`: set `## Version: <version>`. If the client's interface number
   changed, update `## Interface:` only after an in-game check on the new client.
3. `make check` and `make dist`; list the zip's contents (`unzip -l`) and confirm it has
   only the `TinyTweaks/` folder with the TOC, the Lua files listed in it, `README.md`
   and `LICENSE`.
4. Commit: `Release <version>` with the changelog section as the body. Tag:
   `git tag -a v<version> -m "TinyTweaks <version>"`.

## 4. Publish (ask first)

Show the user the commit, the tag and the zip path, and ask before running
`git push origin main --follow-tags` or uploading the zip anywhere. Pushing a tag is
shared and hard to undo.

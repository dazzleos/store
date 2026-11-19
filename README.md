# Store

Dazzle's software server: the system's updates (`os.json`) and the
catalogue of the apps Settings installs (`apps.json`), published as this
repository's "latest" release, from dazzleos/dazzle and dazzleos' app
repositories.

What it lists is in [store.zon](store.zon): the system, the language
packs built with it (store.zon describes them: Dazzle publishes only their
archives), and the apps. Each is listed from one of its
repository's builds (the release each build publishes, tagged
`build-<commit>`): its newest, or the one `store.zon` holds it at with
`.build`. Its files stay where that build published them, and its entry
says so (`base`). While an app's newest build cannot be found (as while it
is being published), it stays as the store last listed it; an app is never
listed from its "latest" release, whose files are replaced by each build. Each archive is checked against its build's catalogue
and signed with the key Dazzle's own builds trust, so app repositories need
no key of their own.

The [Store workflow](.github/workflows/store.yml) makes it every hour, and
when this repository changes, and publishes it if it has changed.

## Making it

```sh
DAZZLE_SIGNING_KEY=<key or key file> scripts/make
```

writes `zig-out/store/apps.json` and `os.json`, with Zig 0.17.1 (`ZIG` to give another
`zig`), curl and jq. `zig build test` runs the tests.

## Adding an app

Add its repository to `store.zon`. Its release workflow publishes each
build as a release tagged `build-<commit>` (as dazzleos/files' does), with
its archive, icon, screenshot and catalogue, made by Dazzle's tools.

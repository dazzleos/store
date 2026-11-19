# Store

The catalogue of the apps Dazzle installs from Settings, Software: one
`apps.json`, published as this repository's "latest" release, listing the
apps of dazzleos' app repositories.

The apps are listed in [store.zon](store.zon). Each is listed from one of
its repository's builds (the release each build publishes, tagged
`build-<commit>`): its newest, or the one `store.zon` holds it at with
`.build`. Its files stay where that build published them, and its entry
says so (`base`). Each archive is checked against its build's catalogue
and signed with the key Dazzle's own builds trust, so app repositories need
no key of their own.

The [Store workflow](.github/workflows/store.yml) makes it every hour, and
when this repository changes, and publishes it if it has changed.

## Making it

```sh
DAZZLE_SIGNING_KEY=<key or key file> scripts/make
```

writes `zig-out/store/apps.json`, with Zig 0.17.1 (`ZIG` to give another
`zig`), curl and jq. `zig build test` runs the tests.

## Adding an app

Add its repository to `store.zon`. Its release workflow publishes each
build as a release tagged `build-<commit>` (as dazzleos/files' does), with
its archive, icon, screenshot and catalogue, made by Dazzle's tools.

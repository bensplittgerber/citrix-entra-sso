# Releasing a new version (CLI)

Everything is done with `git` and the GitHub CLI (`gh`), no browser steps. Versions use `vMAJOR.MINOR.PATCH`
(patch = fix or docs, minor = new script or option, major = breaking change to the config layout).
Identity: `Ben Splittgerber <bensplittgerber@users.noreply.github.com>`. A published tag is never moved.

## 1. Clean tree
```
git status --short                      # must print nothing
```

## 2. Changelog entry
Add a section at the top of `CHANGELOG.md` with the heading `## vX.Y.Z - YYYY-MM-DD`; the release notes are cut
out by that heading.

## 3. Secret and real-name check (both must print `clean`)
```
$hits = git ls-files | Select-String -Pattern '\.local\.json$|^exports/|\.pfx$|\.pem$|\.key$'
if ($hits) { $hits } else { "clean" }
$names = git grep -nIiE '<your real domain>|<your tenant id>|<your client app ids>|<your hostnames>'
if ($names) { $names } else { "clean" }
```
Fill the second pattern with your own names before the first release. Placeholders only in the repo
(`example.org`, `192.0.2.x`, `<tenant-id>`); the public Citrix app id `3a510bb1-...` is not a secret.
Check new screenshots in `docs/img/` by eye (no real host names, tenant or app ids, ticket values).

## 4. Commit, tag, push
```
$ver = "v1.0.0"
git add -A
git commit -m "Release $ver"
git tag -a $ver -m $ver
git push origin main
git push origin $ver
```

## 5. GitHub release with the changelog section as notes
```
$sec = (Get-Content CHANGELOG.md -Raw) -split '(?m)^(?=## )' | Where-Object { $_ -match "^## $ver " }
$sec | Set-Content "$env:TEMP\notes.md"
Get-Content "$env:TEMP\notes.md"        # must not be empty
gh release create $ver --title "citrix-entra-sso $ver" --notes-file "$env:TEMP\notes.md" --latest
```

## 6. Verify
```
git log --oneline -3
gh release list
gh release view $ver
```

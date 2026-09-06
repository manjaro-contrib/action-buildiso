# manjaro-iso-action

Tooling to build and distribute Manjaro on via Github Actions

## Usage example

This action ...

- installs the prerequisites to build Manjaro
- builds a ready to go Manjaro iso
- calculates hashes for the resulting image

It optionally provides:

- GPG-signing
- Distribution to Github Releases
- Upload of the unsplit image to S3-compatible object storage

### Chroot DNS

`buildiso` builds its overlays through `mkchroot` -> `basestrap`, which
copies the host keyring and mirrorlist but not `/etc/resolv.conf`, and
mounts the API filesystems with the `chroot_api_mount` variant that
carries no `resolv.conf` bind - unlike `chroot-run`, used for package
builds, which does. So the chroots resolve nothing, and both consequences
are silent because the build still succeeds:

- `pacman-mirrors` reports `Internet connection appears to be down` and
  generates the mirrorlist by random method rather than by ranking
- post-install scriptlets that fetch anything fail, so e.g.
  `libpamac-flatpak-plugin` ships without its remote configured

`scripts/enable-chroot-dns.sh` writes a resolver into every overlay by
hooking `chroot_create`, the one function all four stages go through. Set
`chroot-nameservers` to override the default `1.1.1.1 8.8.8.8`.

### Object storage

A GitHub release asset is capped at 2 GB, so an image over that is uploaded
as a split zip (`.zip` + `.z01` + ...) and the release never carries the
`.iso` itself. Setting `r2-endpoint`, `r2-bucket` and the two credentials
uploads the image, its signature, hashes and package list to object
storage first, while the unsplit file is still on disk - so there is one
place the image can be downloaded without reassembly.

The upload is skipped entirely when no endpoint or bucket is given, so it
costs nothing for consumers that do not want it.

The set is all-or-nothing. An image whose signature or checksum failed to
upload cannot be verified, and anything serving a `latest` alias would
point at it regardless - so if any part of the set fails, whatever already
landed is removed and the previous build stays in place.

```yaml
      - uses: manjaro-contrib/action-buildiso@main
        with:
          edition: sway
          branch: unstable
          release-tag: ${{ needs.prepare-release.outputs.release_tag }}
          r2-endpoint: ${{ secrets.R2_ENDPOINT }}
          r2-access-key-id: ${{ secrets.R2_ACCESS_KEY_ID }}
          r2-secret-access-key: ${{ secrets.R2_SECRET_ACCESS_KEY }}
          r2-bucket: ${{ secrets.R2_BUCKET }}
          r2-prefix: ${{ needs.prepare-release.outputs.release_tag }}/
```

The following example is a minimal "matrix strategy" setup, that builds minimal and full images for cinnamon, gnome and builds the images each on stable and testing repositories. Refer [here](https://docs.github.com/en/actions/reference/workflow-syntax-for-github-actions#jobsjob_idstrategymatrix) for more information on including / excluding permutations from matrix strategies.

All configuration options and defaults can be found [here](action.yml).

Instead of `manjaro/manjaro-iso-action@main`, please refer to the most current release (e.g. `manjaro/manjaro-iso-action@v1`).

```yaml
name: iso_build
on:
  workflow_dispatch:
  # remove if you don't want to build on a schedule
  schedule:
    - cron:  '30 6 1 * *'
  # remove if you don't want to build when commits are pushed to you main/master branch
  push:
    branches:
      - master
      - main

jobs:
  prepare-release:
    runs-on: ubuntu-20.04
    steps:
      # cancel already running instances of the same action on the currently working on branch
      - uses: styfle/cancel-workflow-action@0.9.0
        with:
          access_token: ${{ github.token }}
      - id: time
        uses: nanzm/get-time-action@v1.1
        with:
          format: 'YYYYMMDDHHmm'
    outputs:
      # generate a common tag to be used in all elements of the matrix strategy
      release_tag: ${{ steps.time.outputs.time }}      
  release:
    runs-on: ubuntu-20.04
    needs: prepare-release    
    strategy:
      matrix:
        ##### EDIT ME #####      
        EDITION: [cinnamon, gnome]
        BRANCH: [stable, testing]
        SCOPE: [minimal,full]
        ###################
    steps:
      # cancel already running instances of the same action on the currently working on branch
      - uses: styfle/cancel-workflow-action@0.9.0
        with:
          access_token: ${{ github.token }}
      - id: image-build
        uses: manjaro/manjaro-iso-action@main
        with:
          edition: ${{ matrix.edition }}
          branch: ${{ matrix.branch }}
          scope: ${{ matrix.scope }}
          version: "21.0"
          kernel: linux510
          code-name: "Ornara"
          # providing a release-tag allows for github releases
          release-tag: ${{ needs.prepare-release.outputs.release_tag }}
      # delete the github release in case of cancellation or failure
      # refer to .github/workflows/cleanup-test-release.yml for rollback strategies concerning the other distribution channels
      - name: rollback github release
        if: ${{ failure() || cancelled() }}
        run: |
          echo ${{ github.token }} | gh auth login --with-token
          gh release delete ${{ needs.prepare-release.outputs.release_tag }} -y --repo ${{ github.repository }}
          git push --delete origin ${{ needs.prepare-release.outputs.release_tag }}
```

### gpg signing

```yaml
- id: image-build
  uses: manjaro/manjaro-iso-action@main
  with:
    ...
    gpg-secret-key-base64: ${{ secrets.gpg_secret_base64 }}
    gpg-passphrase: ${{ secrets.GPG_PASSPHRASE }}
```

### caching

to get an idea how caching might work, please refer [here](.github/workflows/test.yml)

## Distribution channels

all distribution channels can be configured by setting / leaving out of their configuration variables.

### github release

```yaml
- id: image-build
  uses: manjaro/manjaro-iso-action@main
  with:
    ...
    release-tag: ${{ needs.prepare-release.outputs.release_tag }}
- name: rollback github release
  if: ${{ failure() || cancelled() }}
  run: |
    echo ${{ github.token }} | gh auth login --with-token
    gh release delete ${{ needs.prepare-release.outputs.release_tag }} -y --repo ${{ github.repository }}
    git push --delete origin ${{ needs.prepare-release.outputs.release_tag }}
```

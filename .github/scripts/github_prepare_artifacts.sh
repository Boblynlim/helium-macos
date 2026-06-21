#!/bin/bash -eux
# Simple script for packing Helium macOS build artifacts on GitHub Actions

_target_cpu="${1:-x86_64}"

_root_dir="$(dirname "$(greadlink -f "$0")")"
_main_repo="$_root_dir/helium-chromium"
_src_dir="$_root_dir/build/src"

# If build finished successfully
if [[ -f "$_root_dir/build_finished_$_target_cpu.log" ]] ; then
  # For packaging
  _helium_version=$(python3 "$_main_repo/utils/helium_version.py" --tree "$_main_repo" --platform-tree "$_root_dir" --print)

  _file_name="helium_${_helium_version}_${_target_cpu}-macos.dmg"
  _hash_name="${_file_name}.hashes.md"

  cd "$_src_dir"

  xattr -cs out/Default/Helium.app

  # Prepare the certificate for app signing — only when a signing cert is
  # actually configured. With no MACOS_CERTIFICATE secret (dev/fork builds),
  # `security import` chokes on an empty p12 and aborts; skip it so
  # sign_and_package_app.sh falls back to ad-hoc signing and still ships a .dmg.
  if [ -n "${MACOS_CERTIFICATE:-}" ]; then
    echo $MACOS_CERTIFICATE | base64 --decode > "$TMPDIR/certificate.p12"

    security create-keychain -p "$MACOS_CI_KEYCHAIN_PWD" build.keychain
    security default-keychain -s build.keychain
    security unlock-keychain -p "$MACOS_CI_KEYCHAIN_PWD" build.keychain
    security import "$TMPDIR/certificate.p12" -k build.keychain -P "$MACOS_CERTIFICATE_PWD" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$MACOS_CI_KEYCHAIN_PWD" build.keychain
  else
    echo "warn: MACOS_CERTIFICATE not set; building an ad-hoc-signed (unsigned) .dmg" >&2
  fi

  if ! [ -z "${PROD_MACOS_SPECIAL_ENTITLEMENTS_PROFILE_B64:-}" ]; then
    export PROD_MACOS_SPECIAL_ENTITLEMENTS_PROFILE_PATH=$(mktemp)
    echo "$PROD_MACOS_SPECIAL_ENTITLEMENTS_PROFILE_B64" \
      | base64 --decode > "$PROD_MACOS_SPECIAL_ENTITLEMENTS_PROFILE_PATH"
  fi

  export OUT_DMG_PATH="$_root_dir/$_file_name"
  export NEEDS_APPDMG=1
  "$_root_dir/sign_and_package_app.sh"

  if ! [ -z "${PROD_MACOS_SPECIAL_ENTITLEMENTS_PROFILE_B64:-}" ]; then
    rm -f "$PROD_MACOS_SPECIAL_ENTITLEMENTS_PROFILE_PATH"
  fi

  cd "$_root_dir"
  echo -e "md5: \nsha1: \nsha256: " | tee ./hash_types.txt
  { md5sum "$_file_name" ; sha1sum "$_file_name" ; sha256sum "$_file_name" ; } | tee ./sums.txt

  _hash_md=$(paste ./hash_types.txt ./sums.txt | awk '{print $1 " " $2}')

  echo "file_name=$_file_name" >> $GITHUB_OUTPUT

  _gh_run_href="https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

  printf '[Hashes](https://en.wikipedia.org/wiki/Cryptographic_hash_function) for the disk image `%s`: \n' "$_file_name" | tee -a ./${_hash_name}
  printf '\n```\n%s\n```\n' "$_hash_md" | tee -a ./${_hash_name}

  # Use separate folder for build product, so that it can be used as individual asset in case the release action fails
  mkdir -p release_asset
  mv -vn ./*.dmg release_asset/ || true

  if [ "$_target_cpu" = "x86_64" ]; then
    DELTA_ARG="--x86"
  else
    DELTA_ARG="--arm"
  fi

  # Sparkle deltas are auto-update artifacts (diff vs previous releases); not
  # needed for a dev/fork build, and a fork with no prior releases may have
  # nothing to diff. Don't let a delta hiccup discard the already-built .dmg.
  ./github_prep_sparkle_deltas.sh \
    $DELTA_ARG "./release_asset/$_file_name" \
    --out ./release_asset || echo "warn: sparkle delta generation failed; shipping .dmg without deltas" >&2

  ls -kahl release_asset/
  du -hs release_asset/
fi

gsync --file-system "$_src_dir"

# Needs to be compressed to stay below GitHub's upload limit 2 GB (?!) 2020-11-24; used to be  5-8GB (?)
tar -C build -c -f - src | zstd -vv -11 -T0 -o build_src.tar.zst

sha256sum ./build_src.tar.zst | tee ./sums.txt

mkdir -p upload_part_build
mv -vn ./*.zst ./sums.txt upload_part_build/ || true
cp -va ./*.log upload_part_build/

ls -kahl upload_part_build/
du -hs upload_part_build/

mkdir upload_logs
mv -vn ./*.log upload_logs/

ls -kahl upload_logs/
du -hs upload_logs/

echo "ready for upload action"

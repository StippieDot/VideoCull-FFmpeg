# Shared helpers. Sourced by the other scripts; expects ROOT to be set.

# Prints "name version file sha256 url" for every entry of a lock file.
lock_entries() {
  grep -vE '^\s*(#|$)' "$1"
}

# Prints one field of a sources.lock entry: lock_field NAME COLUMN (1=name ... 5=url).
lock_field() {
  local value
  value="$(lock_entries "$ROOT/sources.lock" | awk -v n="$1" -v c="$2" '$1 == n { print $c }')"
  [[ -n "$value" ]] || { echo "sources.lock has no entry '$1'" >&2; return 1; }
  printf '%s\n' "$value"
}

# Unpacks a verified source archive into a fresh WORK/NAME, applies our patches from
# patches/NAME/*.patch, and prints the directory.
unpack() {
  local name="$1" file dir patch_file
  file="$SRC/$(lock_field "$name" 3)"
  dir="$WORK/$name"
  rm -rf "$dir"
  mkdir -p "$dir"
  tar -xf "$file" -C "$dir" --strip-components=1
  for patch_file in "$ROOT/patches/$name"/*.patch; do
    [[ -f "$patch_file" ]] || continue
    patch -d "$dir" -p1 --forward --input="$patch_file" >&2
  done
  printf '%s\n' "$dir"
}

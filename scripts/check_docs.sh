#!/bin/zsh

# Fails when docs drift from the tree: a relative Markdown link that does not
# resolve, or a journey proof in docs/voice_cujs.md that names a missing test.

set -euo pipefail

repo_root="${HC_DOCS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$repo_root"

failures=()
tracked=("${(@f)$(git ls-files)}")
tracked_set=" ${tracked[*]} "

for doc in "${(@f)$(git ls-files '*.md')}"; do
  doc_dir="${doc:h}"
  [[ "$doc_dir" == "$doc" ]] && doc_dir="."
  # Captures the target of every inline link, ignoring images' alt text.
  for target in "${(@f)$(grep -oE '\]\([^) ]+\)' "$doc" | sed -E 's/^\]\(//; s/\)$//' || true)}"; do
    [[ -z "$target" || "$target" == *://* || "$target" == mailto:* || "$target" == \#* ]] && continue
    link_path="${target%%#*}"
    resolved="${doc_dir}/${link_path}"
    [[ -e "$resolved" ]] || failures+=("$doc: broken link $target")
  done
done

# The Proof column is the last cell of each journey row.
journeys="docs/voice_cujs.md"
for row in "${(@f)$(grep -E '^\| [A-Z]+[0-9]+ \|' "$journeys")}"; do
  proof="${${row%|}##*|}"
  for token in "${(@f)$(print -r -- "$proof" | grep -oE '`[^`]+`' | tr -d '`')}"; do
    # Expands `prefix_{a,b}_suffix` into each named file without eval.
    if [[ "$token" =~ '^(.*)\{([^}]*)\}(.*)$' ]]; then
      expanded=()
      for alternative in "${(@s:,:)match[2]}"; do
        expanded+=("${match[1]}${alternative}${match[3]}")
      done
    else
      expanded=("$token")
    fi
    for name in "${expanded[@]}"; do
      if [[ "$name" == */* ]]; then
        [[ -e "$name" ]] || failures+=("$journeys: missing path $name")
      elif [[ "$name" == test* ]]; then
        git grep -q "func ${name}(" -- 'apps/**/*.swift' 'Tests/**/*.swift' \
          || failures+=("$journeys: missing test function $name")
      elif [[ "$tracked_set" != *"/${name}.swift "* && "$tracked_set" != *"/${name} "* ]]; then
        failures+=("$journeys: missing test file $name")
      fi
    done
  done
done

if (( ${#failures} )); then
  print -u2 -l "${failures[@]}"
  exit 1
fi
print "Docs links and journey proofs resolve."

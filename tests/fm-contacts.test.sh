#!/usr/bin/env bash
# Behavior tests for bin/fm-contacts.sh.
#
# Every case runs the executable public interface against a temporary FM_HOME
# and asserts its printed output, exit code, and stored book; none asserts
# internal source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTACTS="$ROOT/bin/fm-contacts.sh"
TMP_ROOT=$(fm_test_tmproot fm-contacts)

# new_home <name>: echo a fresh empty FM_HOME.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home"
  printf '%s\n' "$home"
}

# contacts <home> <args...>: run the contact book in <home>, stdout to
# $TMP_ROOT/out and stderr to $TMP_ROOT/err; return its exit code.
contacts() {
  local home=$1
  shift
  FM_HOME="$home" "$CONTACTS" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
}

# json_field <file> <python expression over d>: print one value from a JSON file.
json_field() {
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1], encoding="utf-8")); print(eval(sys.argv[2]))' "$1" "$2"
}

# seed_book <home>: the shared fixture book for the resolve cases.
seed_book() {
  local home=$1
  contacts "$home" add --id site-it-lead --name "José Pérez" \
    --alias "el de sistemas" --alias "José" --role "Site IT, location team" \
    --trust external --language es --email jose.perez@example.com \
    --added-by "captain words: add José, site IT" \
    || fail "seed: adding site-it-lead failed: $(cat "$TMP_ROOT/err")"
  contacts "$home" add --id maria-lopez --name "María López" --role "Finance" \
    --trust internal --language es --email maria.lopez@example.com --added-by "seed" \
    || fail "seed: adding maria-lopez failed: $(cat "$TMP_ROOT/err")"
  contacts "$home" add --id maria-gomez --name "Maria Gomez" --role "Legal" \
    --trust internal --language es --email mgomez@example.org --added-by "seed" \
    || fail "seed: adding maria-gomez failed: $(cat "$TMP_ROOT/err")"
  contacts "$home" add --id me --name "Captain Self" --alias "me" --role "Owner" \
    --trust self --language en --email owner@example.net --added-by "seed" \
    || fail "seed: adding me failed: $(cat "$TMP_ROOT/err")"
}

test_add_stores_entry() {
  local home book rc mode
  home=$(new_home add)
  contacts "$home" add --id site-it-lead --name "José Pérez" --alias "el de sistemas" \
    --role "Site IT" --trust external --language es --email jose.perez@example.com \
    --added-by "captain words"
  rc=$?
  expect_code 0 "$rc" "add of a valid contact"
  book="$home/data/contacts.json"
  assert_present "$book" "add creates data/contacts.json"
  assert_equals "1" "$(json_field "$book" 'd["version"]')" "the book is schema version 1"
  assert_equals "José Pérez" "$(json_field "$book" 'd["contacts"][0]["name"]')" "the stored name keeps its accents"
  assert_equals "['email']" "$(json_field "$book" 'd["contacts"][0]["preferred"]')" "preferred defaults to the channels that have an address"
  assert_equals "None" "$(json_field "$book" 'd["contacts"][0]["whatsapp"]')" "an absent channel address is null"
  assert_equals "$(date +%Y-%m-%d)" "$(json_field "$book" 'd["contacts"][0]["added"]')" "added is today's date"
  assert_grep '"José Pérez"' "$book" "the book is written as UTF-8 text, not ASCII escapes"
  assert_equals "jose.perez@example.com" "$(json_field "$TMP_ROOT/out" 'd["email"]')" "add prints the stored entry as JSON"
  mode=$(python3 -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$book")
  assert_equals "600" "$mode" "the book is private (0600)"
  pass "fm-contacts: add validates, stores, and prints a contact"
}

test_add_validation_failures() {
  local home
  home=$(new_home invalid)
  # expect_refusal <message substring> <add args...>
  expect_refusal() {
    local needle=$1 rc
    shift
    contacts "$home" add "$@"
    rc=$?
    expect_code 1 "$rc" "add refusal ($needle)"
    assert_contains "$(cat "$TMP_ROOT/err")" "$needle" "the refusal names the problem"
  }
  local base=(--name "Ana" --role "Ops" --language en --added-by t)
  expect_refusal "lowercase slug" --id "Ana Ops" "${base[@]}" --trust internal --email ana@example.com
  expect_refusal "trust must be one of" --id ana "${base[@]}" --trust friend --email ana@example.com
  expect_refusal "language must be one of" --id ana --name Ana --role Ops --added-by t --language fr --trust internal --email ana@example.com
  expect_refusal "exactly one @" --id ana "${base[@]}" --trust internal --email ana.example.com
  expect_refusal "exactly one @" --id ana "${base[@]}" --trust internal --email "ana@@example.com"
  expect_refusal "at least one address" --id ana "${base[@]}" --trust internal
  expect_refusal "preferred channel whatsapp has no address" --id ana "${base[@]}" --trust internal --email ana@example.com --preferred whatsapp
  expect_refusal "required" --id ana --name Ana --role Ops --language en --trust internal --email ana@example.com
  assert_absent "$home/data/contacts.json" "a refused add never creates the book"
  pass "fm-contacts: add refuses invalid fields with a clear reason"
}

test_add_refuses_duplicates() {
  local home rc
  home=$(new_home dup)
  contacts "$home" add --id ana --name Ana --role Ops --trust internal --language en \
    --email ana@example.com --added-by t || fail "first add failed: $(cat "$TMP_ROOT/err")"
  contacts "$home" add --id ana --name Other --role Ops --trust internal --language en \
    --email other@example.com --added-by t
  rc=$?
  expect_code 1 "$rc" "duplicate id"
  assert_contains "$(cat "$TMP_ROOT/err")" "duplicate id" "duplicate id refusal"
  contacts "$home" add --id ana-two --name "Ana Two" --role Ops --trust internal --language en \
    --email ANA@Example.com --added-by t
  rc=$?
  expect_code 1 "$rc" "duplicate email"
  assert_contains "$(cat "$TMP_ROOT/err")" "already used by contact 'ana'" "duplicate email refusal names the owner"
  assert_equals "1" "$(json_field "$home/data/contacts.json" 'len(d["contacts"])')" "refused adds leave the book unchanged"
  pass "fm-contacts: add refuses a duplicate id or email"
}

test_list_masks_addresses() {
  local home out rc
  home=$(new_home list)
  seed_book "$home"
  contacts "$home" list
  rc=$?
  expect_code 0 "$rc" "list"
  out=$(cat "$TMP_ROOT/out")
  assert_contains "$out" $'site-it-lead\tJosé Pérez\tSite IT, location team\texternal\tj***@example.com' "list prints id, name, role, trust, and masked email"
  assert_contains "$out" $'maria-gomez\tMaria Gomez\tLegal\tinternal\tm***@example.org' "list masks every contact"
  assert_not_contains "$out" "jose.perez@" "list never prints a full address"
  assert_not_contains "$out" "mgomez@" "list never prints a full address"
  assert_equals "4" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "list prints one line per contact"
  pass "fm-contacts: list prints one masked line per contact"
}

test_show_prints_full_entry() {
  local home rc
  home=$(new_home show)
  seed_book "$home"
  contacts "$home" show maria-gomez
  rc=$?
  expect_code 0 "$rc" "show of a known id"
  assert_equals "mgomez@example.org" "$(json_field "$TMP_ROOT/out" 'd["email"]')" "show prints the full address"
  assert_equals "Legal" "$(json_field "$TMP_ROOT/out" 'd["role"]')" "show prints the whole entry"
  contacts "$home" show nobody
  rc=$?
  expect_code 1 "$rc" "show of an unknown id"
  assert_contains "$(cat "$TMP_ROOT/err")" "no contact with id 'nobody'" "show names the missing id"
  pass "fm-contacts: show prints one full entry"
}

# expect_resolve <home> <exit> <first id or -> <first tier or -> <match count> <words...>
expect_resolve() {
  local home=$1 code=$2 id=$3 tier=$4 count=$5 rc
  shift 5
  contacts "$home" resolve "$@"
  rc=$?
  expect_code "$code" "$rc" "resolve '$*'"
  assert_equals "$count" "$(json_field "$TMP_ROOT/out" 'len(d["matches"])')" "resolve '$*' match count"
  if [ "$count" != 0 ]; then
    assert_equals "$id" "$(json_field "$TMP_ROOT/out" 'd["matches"][0]["id"]')" "resolve '$*' first match"
    assert_equals "$tier" "$(json_field "$TMP_ROOT/out" 'd["matches"][0]["tier"]')" "resolve '$*' tier"
  fi
}

test_resolve() {
  local home out
  home=$(new_home resolve)
  seed_book "$home"

  expect_resolve "$home" 0 me exact 1 me
  out=$(cat "$TMP_ROOT/out")
  assert_contains "$out" '"masked_email": "o***@example.net"' "resolve output carries the masked email"
  assert_not_contains "$out" "owner@example.net" "resolve never prints a full address"

  # Spanish dictation: the article is dropped on both sides.
  expect_resolve "$home" 0 site-it-lead exact 1 el de sistemas
  assert_equals "de sistemas" "$(json_field "$TMP_ROOT/out" 'd["normalized"]')" "resolve reports the normalized query"
  assert_equals "el de sistemas" "$(json_field "$TMP_ROOT/out" 'd["query"]')" "resolve reports the joined query"
  # Accent folding: "Jose" matches the alias "José", and one quoted argument works too.
  expect_resolve "$home" 0 site-it-lead exact 1 "Jose"
  expect_resolve "$home" 0 site-it-lead exact 1 "JOSE PEREZ."

  # A dictation typo within edit distance 2 needs confirmation.
  expect_resolve "$home" 3 site-it-lead fuzzy 1 Jsoe Perez
  assert_equals "2" "$(json_field "$TMP_ROOT/out" 'd["matches"][0]["distance"]')" "fuzzy distance is reported"

  # Two contacts share a first name: ambiguous, both offered.
  expect_resolve "$home" 3 maria-gomez prefix 2 maria
  assert_equals "maria-lopez" "$(json_field "$TMP_ROOT/out" 'd["matches"][1]["id"]')" "both namesakes are offered"
  # A word prefix in order narrows it to one, but still needs confirmation.
  expect_resolve "$home" 3 maria-lopez prefix 1 maria lop

  # Nobody by that name.
  expect_resolve "$home" 2 - - 0 Roberto Sanchez
  pass "fm-contacts: resolve scores exact, prefix, fuzzy, ambiguous, and missing names"
}

test_missing_book_is_empty() {
  local home rc
  home=$(new_home empty)
  contacts "$home" list
  rc=$?
  expect_code 0 "$rc" "list of a missing book"
  assert_equals "" "$(cat "$TMP_ROOT/out")" "a missing book lists nothing"
  contacts "$home" resolve anybody
  rc=$?
  expect_code 2 "$rc" "resolve against a missing book"
  assert_absent "$home/data/contacts.json" "reading never creates the book"
  pass "fm-contacts: a missing book is an empty book"
}

test_refuses_unsupported_version() {
  local home rc
  home=$(new_home version)
  mkdir -p "$home/data"
  printf '{"version": 2, "contacts": []}\n' > "$home/data/contacts.json"
  contacts "$home" list
  rc=$?
  expect_code 1 "$rc" "list of a version 2 book"
  assert_contains "$(cat "$TMP_ROOT/err")" "unsupported version 2" "the refusal names the version"
  contacts "$home" resolve anybody
  rc=$?
  expect_code 1 "$rc" "resolve of a version 2 book is an error, not a no-match"
  pass "fm-contacts: a book whose version is not 1 is refused"
}

test_help_and_usage() {
  local out rc
  out=$(FM_HOME="$TMP_ROOT" "$CONTACTS" --help 2>&1)
  rc=$?
  expect_code 0 "$rc" "--help"
  for sub in add list show resolve; do
    assert_contains "$out" "fm-contacts.sh $sub" "--help lists $sub"
  done
  FM_HOME="$TMP_ROOT" "$CONTACTS" bogus >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "unknown subcommand"
  contacts "$TMP_ROOT" resolve
  rc=$?
  expect_code 1 "$rc" "resolve without words is a usage error, not a no-match"
  pass "fm-contacts: --help and usage errors"
}

test_add_stores_entry
test_add_validation_failures
test_add_refuses_duplicates
test_list_masks_addresses
test_show_prints_full_entry
test_resolve
test_missing_book_is_empty
test_refuses_unsupported_version
test_help_and_usage

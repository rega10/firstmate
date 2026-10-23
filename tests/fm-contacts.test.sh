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
  contacts "$home" add --id me --name "Captain Self" --alias "me" --alias "mi" --role "Owner" \
    --trust self --language en --email owner@example.net --added-by "seed" \
    || fail "seed: adding me failed: $(cat "$TMP_ROOT/err")"
}

test_add_stores_entry() {
  local home book rc mode
  home=$(new_home add)
  contacts "$home" add --id site-it-lead --name "José Pérez" --alias "el de sistemas" \
    --role "Site IT" --trust external --language es --email jose.perez@example.com \
    --added-by "captain words" </dev/null
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
  assert_equals "captain words" "$(json_field "$book" 'd["contacts"][0]["added_by"]')" "add records the captain's words without prompting"
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
  expect_refusal "preferred channel must be one of" --id ana "${base[@]}" --trust internal --email ana@example.com --preferred fax
  expect_refusal "required" --id ana --name Ana --role Ops --language en --trust internal --email ana@example.com
  assert_absent "$home/data/contacts.json" "a refused add never creates the book"
  pass "fm-contacts: add refuses invalid fields with a clear reason"
}

test_preferred_allows_absent_addresses() {
  local home channel fallback rc
  local address=()
  for channel in email telegram imessage whatsapp; do
    home=$(new_home "preferred-$channel")
    if [ "$channel" = email ]; then
      address=(--telegram-chat-id 123)
      fallback=telegram
    else
      address=(--email ana@example.com)
      fallback=email
    fi
    contacts "$home" add --id ana --name Ana --role Ops --trust internal --language en \
      "${address[@]}" --preferred "$channel" --preferred "$fallback" --added-by t
    rc=$?
    expect_code 0 "$rc" "add with absent preferred $channel address"
    assert_equals "['$channel', '$fallback']" "$(json_field "$TMP_ROOT/out" 'd["preferred"]')" "add preserves preference order"
    contacts "$home" list
    rc=$?
    expect_code 0 "$rc" "list with absent preferred $channel address"
    assert_contains "$(cat "$TMP_ROOT/out")" $'ana\tAna\tOps\tinternal' "list loads the contact"
    contacts "$home" show ana
    rc=$?
    expect_code 0 "$rc" "show with absent preferred $channel address"
    assert_equals "['$channel', '$fallback']" "$(json_field "$TMP_ROOT/out" 'd["preferred"]')" "show preserves preference order"
    expect_resolve "$home" 0 ana exact 1 Ana
    contacts "$home" add --id luis --name Luis --role Ops --trust internal --language en \
      --email luis@example.com --added-by t
    rc=$?
    expect_code 0 "$rc" "add loads a book with absent preferred $channel address"
  done
  pass "fm-contacts: preferred channels may lack addresses on add and load"
}

test_add_refuses_duplicate_ids() {
  local home rc
  home=$(new_home dup)
  contacts "$home" add --id ana --name Ana --role Ops --trust internal --language en \
    --email ana@example.com --added-by t || fail "first add failed: $(cat "$TMP_ROOT/err")"
  contacts "$home" add --id ana --name Other --role Ops --trust internal --language en \
    --email other@example.com --added-by t
  rc=$?
  expect_code 1 "$rc" "duplicate id"
  assert_contains "$(cat "$TMP_ROOT/err")" "duplicate id" "duplicate id refusal"
  assert_equals "1" "$(json_field "$home/data/contacts.json" 'len(d["contacts"])')" "refused adds leave the book unchanged"
  pass "fm-contacts: add refuses a duplicate id"
}

test_shared_addresses() {
  local home id rc
  home=$(new_home shared)
  for id in ana luis; do
    contacts "$home" add --id "$id" --name "$id" --role Ops --trust internal --language en \
      --email ops@example.com --telegram-chat-id=-123 --imessage team@example.com \
      --whatsapp +12345678901 --added-by t
    rc=$?
    expect_code 0 "$rc" "add $id with shared addresses on every channel"
  done
  assert_equals "2" "$(json_field "$home/data/contacts.json" 'len(d["contacts"])')" "both contacts are stored"
  contacts "$home" list
  rc=$?
  expect_code 0 "$rc" "list loads shared addresses"
  assert_equals "2" "$(wc -l < "$TMP_ROOT/out" | tr -d ' ')" "list includes both contacts"
  contacts "$home" show luis
  rc=$?
  expect_code 0 "$rc" "show loads shared addresses"
  assert_equals "['ops@example.com', '-123', 'team@example.com', '+12345678901']" \
    "$(json_field "$TMP_ROOT/out" '[d[f] for f in ("email", "telegram_chat_id", "imessage", "whatsapp")]')" "show preserves all shared addresses"
  expect_resolve "$home" 0 ana exact 1 ana
  expect_resolve "$home" 0 luis exact 1 luis
  contacts "$home" add --id other --name Other --role Ops --trust internal --language en \
    --email other@example.com --added-by t
  rc=$?
  expect_code 0 "$rc" "add loads shared addresses"
  pass "fm-contacts: contacts may share addresses on every channel"
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

test_preferred_address_masking() {
  local home kind channel missing masked address rc out
  local address_args=()
  for kind in email telegram imessage whatsapp imessage-email telegram-short telegram-single; do
    channel=$kind
    case "$kind" in
      email) address=person@example.com; masked='p***@example.com'; address_args=(--email "$address") ;;
      telegram) address=-123456789; masked='***789'; address_args=(--telegram-chat-id="$address") ;;
      imessage) address=+12345678901; masked='***901'; address_args=(--imessage "$address") ;;
      whatsapp) address=+19876543210; masked='***210'; address_args=(--whatsapp "$address") ;;
      imessage-email) channel=imessage; address=team@example.com; masked='***com'; address_args=(--imessage "$address") ;;
      telegram-short) channel=telegram; address=123; masked='***23'; address_args=(--telegram-chat-id "$address") ;;
      telegram-single) channel=telegram; address=1; masked='***'; address_args=(--telegram-chat-id "$address") ;;
    esac
    if [ "$channel" = email ]; then missing=telegram; else missing=email; fi
    home=$(new_home "mask-$kind")
    contacts "$home" add --id recipient --name Recipient --role "Site Ops" --trust internal \
      --language en "${address_args[@]}" --preferred "$missing" --preferred "$channel" --added-by t \
      || fail "adding $kind masking fixture failed"
    contacts "$home" list
    rc=$?
    expect_code 0 "$rc" "list masks $kind"
    assert_equals "$(printf 'recipient\tRecipient\tSite Ops\tinternal\t%s' "$masked")" \
      "$(cat "$TMP_ROOT/out")" "list selects and masks $kind after skipping an absent address"
    expect_resolve "$home" 0 recipient exact 1 Recipient
    assert_equals "$masked" "$(json_field "$TMP_ROOT/out" 'd["matches"][0]["masked_address"]')" "resolve uses the same mask for $kind"
    assert_equals "Site Ops" "$(json_field "$TMP_ROOT/out" 'd["matches"][0]["role"]')" "resolve includes the role for $kind"
    out=$(json_field "$TMP_ROOT/out" 'd["matches"][0]["masked_address"]')
    assert_not_contains "$out" "$address" "the mask never includes the full $kind address"
  done

  home=$(new_home mask-order)
  contacts "$home" add --id recipient --name Recipient --role Ops --trust internal --language en \
    --email person@example.com --whatsapp +12345678901 --preferred whatsapp --preferred email --added-by t \
    || fail "adding preference order fixture failed"
  expect_resolve "$home" 0 recipient exact 1 Recipient
  assert_equals '***901' "$(json_field "$TMP_ROOT/out" 'd["matches"][0]["masked_address"]')" "masking follows preference order when multiple addresses exist"
  assert_not_contains "$(cat "$TMP_ROOT/out")" 'person@example.com' "resolve does not reveal an unselected address"
  contacts "$home" list
  rc=$?
  expect_code 0 "$rc" "list follows preference order"
  assert_equals $'recipient\tRecipient\tOps\tinternal\t***901' "$(cat "$TMP_ROOT/out")" "list masks the first available preferred address"
  contacts "$home" add --id second --name Recipient --role Legal --trust external --language en \
    --telegram-chat-id 123456789 --added-by t || fail "adding ambiguous masking fixture failed"
  expect_resolve "$home" 3 recipient exact 2 Recipient
  assert_equals "['Ops', 'Legal']" "$(json_field "$TMP_ROOT/out" '[m["role"] for m in d["matches"]]')" "ambiguous exact matches include their roles"
  assert_equals "['***901', '***789']" "$(json_field "$TMP_ROOT/out" '[m["masked_address"] for m in d["matches"]]')" "ambiguous exact matches include non-email masks"

  home=$(new_home mask-unavailable)
  contacts "$home" add --id recipient --name Recipient --role Ops --trust internal --language en \
    --email person@example.com --preferred telegram --added-by t || fail "adding unavailable preference fixture failed"
  expect_resolve "$home" 0 recipient exact 1 Recipient
  assert_equals None "$(json_field "$TMP_ROOT/out" 'd["matches"][0]["masked_address"]')" "resolve has no mask when preferred addresses are absent"
  contacts "$home" list
  rc=$?
  expect_code 0 "$rc" "list with no preferred address"
  assert_equals $'recipient\tRecipient\tOps\tinternal\t-' "$(cat "$TMP_ROOT/out")" "list marks an absent preferred address"
  pass "fm-contacts: list and resolve share preference order and masking for every channel"
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
  assert_equals 'o***@example.net' "$(json_field "$TMP_ROOT/out" 'd["matches"][0]["masked_address"]')" "resolve output carries the masked address"
  assert_equals Owner "$(json_field "$TMP_ROOT/out" 'd["matches"][0]["role"]')" "an exact match includes its role"
  assert_not_contains "$out" "owner@example.net" "resolve never prints a full address"
  expect_resolve "$home" 0 me exact 1 mi

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
  assert_equals "Site IT, location team" "$(json_field "$TMP_ROOT/out" 'd["matches"][0]["role"]')" "a fuzzy match includes its role"
  assert_equals 'j***@example.com' "$(json_field "$TMP_ROOT/out" 'd["matches"][0]["masked_address"]')" "a fuzzy match includes its masked address"

  # Two contacts share a first name: ambiguous, both offered.
  expect_resolve "$home" 3 maria-gomez prefix 2 maria
  assert_equals "maria-lopez" "$(json_field "$TMP_ROOT/out" 'd["matches"][1]["id"]')" "both namesakes are offered"
  assert_equals "['Legal', 'Finance']" "$(json_field "$TMP_ROOT/out" '[m["role"] for m in d["matches"]]')" "ambiguous prefix matches include distinct roles"
  assert_equals "['m***@example.org', 'm***@example.com']" \
    "$(json_field "$TMP_ROOT/out" '[m["masked_address"] for m in d["matches"]]')" "ambiguous prefix matches include masked addresses"
  # A word prefix in order narrows it to one, but still needs confirmation.
  expect_resolve "$home" 3 maria-lopez prefix 1 maria lop

  # Nobody by that name.
  expect_resolve "$home" 2 - - 0 Roberto Sanchez
  pass "fm-contacts: resolve scores exact, prefix, fuzzy, ambiguous, and missing names"
}

test_resolve_ignores_ids() {
  local home
  home=$(new_home names-only)
  contacts "$home" add --id maria --name "María López" --role Finance --trust internal \
    --language es --email maria@example.com --added-by t || fail "adding María López failed"
  contacts "$home" add --id maria-ruiz --name "María Ruiz" --role Legal --trust internal \
    --language es --email ruiz@example.com --added-by t || fail "adding María Ruiz failed"
  expect_resolve "$home" 3 maria-ruiz prefix 2 maria
  assert_equals "maria" "$(json_field "$TMP_ROOT/out" 'd["matches"][1]["id"]')" "an id does not hide the other namesake"
  contacts "$home" add --id secret-recipient --name Ana --role Ops --trust internal \
    --language en --email ana@example.com --added-by t || fail "adding Ana failed"
  expect_resolve "$home" 2 - - 0 secret recipient
  expect_resolve "$home" 2 - - 0 secret
  expect_resolve "$home" 2 - - 0 secrex recipient
  contacts "$home" add --id me --name "Captain Self" --role Owner --trust self \
    --language en --email owner@example.com --added-by t || fail "adding owner failed"
  expect_resolve "$home" 2 - - 0 me
  pass "fm-contacts: resolve matches names and aliases without matching ids"
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

test_single_mailbox_addresses() {
  local home field address command
  local command_args=()
  home=$(new_home single-mailbox)
  for field in email imessage; do
    for address in 'ops@example.com,postmaster' 'ops@example.com;postmaster' \
      'ops @example.com' 'ops@example.com postmaster' '<ops@example.com>' \
      'ops@example.com>' 'ops@@example.com' '@example.com' 'ops@example' \
      $'ops@example.com\npostmaster' $'ops@example.com\tpostmaster'; do
      contacts "$home" add --id recipient --name Recipient --role Ops --trust internal \
        --language en "--$field" "$address" --added-by test
      expect_code 1 "$?" "add refuses an invalid $field mailbox"
      assert_absent "$home/data/contacts.json" "a mailbox refusal does not store the contact"
    done
  done
  seed_book "$home"
  cp "$home/data/contacts.json" "$TMP_ROOT/single-mailbox-valid.json"
  for field in email imessage; do
    cp "$TMP_ROOT/single-mailbox-valid.json" "$home/data/contacts.json"
    python3 - "$home/data/contacts.json" "$field" <<'PYBOOK'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
book = json.loads(path.read_text())
book['contacts'][0][sys.argv[2]] = 'ops@example.com,postmaster'
path.write_text(json.dumps(book))
PYBOOK
    for command in list show resolve add; do
      case "$command" in
        list) command_args=(list) ;;
        show) command_args=(show site-it-lead) ;;
        resolve) command_args=(resolve José) ;;
        add) command_args=(add --id other --name Other --role Ops --trust internal --language en --email other@example.com --added-by test) ;;
      esac
      contacts "$home" "${command_args[@]}"
      expect_code 1 "$?" "$command refuses a stored comma-separated $field address"
      assert_contains "$(cat "$TMP_ROOT/err")" "$field must" "the error names the invalid field"
      assert_equals "4" "$(json_field "$home/data/contacts.json" 'len(d["contacts"])')" "a refused load leaves the book unchanged"
    done
  done
  pass "fm-contacts: add and every reader require a single email mailbox"
}

test_add_stores_entry
test_add_validation_failures
test_preferred_allows_absent_addresses
test_add_refuses_duplicate_ids
test_shared_addresses
test_list_masks_addresses
test_preferred_address_masking
test_show_prints_full_entry
test_resolve
test_resolve_ignores_ids
test_missing_book_is_empty
test_refuses_unsupported_version
test_help_and_usage
test_single_mailbox_addresses

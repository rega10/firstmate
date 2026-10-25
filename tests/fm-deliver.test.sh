#!/usr/bin/env bash
# Behavior tests for bin/fm-deliver.sh.
#
# Every case runs the executable public interface against a temporary FM_HOME
# whose contact book is written through bin/fm-contacts.sh add, and asserts the
# exit code, the printed output, the send log, and the arguments the mail plane
# received. The mail plane is replaced by a stub: the test runs fm-deliver.sh
# from a scratch bin directory of symlinks to the real scripts in which only
# fm-mail.sh is a fake that records its argv, stdin, and whether the password
# arrived. Link mode runs a stub sharing command that records each call's argv
# and prints a fake signed URL. No case asserts internal source bytes.
set -u
# The send settings come from each case, never from the caller's environment.
unset FM_DELIVER_MAX_BYTES FM_MAIL_MAX_ATTACH_BYTES FM_DELIVER_SHARE_CMD

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-deliver)
BIN="$TMP_ROOT/bin"
CAPTURE="$TMP_ROOT/capture"
PASS_VALUE="test-secret-pass-value"
mkdir -p "$BIN" "$CAPTURE"
for f in "$ROOT"/bin/*; do
  ln -s "$f" "$BIN/$(basename "$f")"
done
rm -f "$BIN/fm-mail.sh"
cat > "$BIN/fm-mail.sh" <<'SH'
#!/usr/bin/env bash
# Stub mail plane: record the call, then succeed or fail like fm-mail.sh.
cap="$FM_DELIVER_TEST_CAPTURE"
printf '%s\n' "$@" > "$cap/argv"
cat > "$cap/stdin"
if [ "${FM_MAIL_PASS:-}" = test-secret-pass-value ]; then
  echo yes > "$cap/password-arrived"
fi
to=""
attachments=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --attach) attachments=$((attachments + 1)); shift 2 ;;
    --) to=$2; break ;;
    *) shift ;;
  esac
done
if [ -n "${FM_DELIVER_TEST_MAIL_FAIL:-}" ]; then
  echo "fm-mail send refused recipients: $to" >&2
  exit 1
fi
echo "sent to $to (attachments: $attachments) message-id: <delivery-test@example.net>"
SH
chmod +x "$BIN/fm-mail.sh"
SHARE="$TMP_ROOT/share.sh"
cat > "$SHARE" <<'SH'
#!/usr/bin/env bash
# Stub sharing command: append one line per call with its argv, then upload
# or print a fake signed link, or fail as FM_DELIVER_TEST_SHARE_FAIL says.
cap="$FM_DELIVER_TEST_CAPTURE"
if [ "$1" = copy ]; then
  printf 'copy %s %s\n' "${2##*/}" "$3" >> "$cap/share-argv"
  printf '%s\n' "$2" >> "$cap/share-sources"
  python3 -I -c 'import os, sys; p = sys.argv[1]; print("%o %o" % (os.stat(p).st_mode & 0o777, os.stat(os.path.dirname(p)).st_mode & 0o777))' \
    "$2" >> "$cap/share-modes"
else
  printf '%s\n' "$*" >> "$cap/share-argv"
fi
if [ "${FM_MAIL_PASS:-}" = test-secret-pass-value ]; then
  echo yes > "$cap/share-env-arrived"
fi
case "${FM_DELIVER_TEST_SHARE_FAIL:-}:$1" in
  copy:copy|link:link)
    echo "share stub: $1 failed" >&2
    exit 3
    ;;
  badurl:link)
    echo "http://share.example.net/plain/$2"
    exit 0
    ;;
esac
if [ "$1" = copy ]; then
  if [ -n "${FM_DELIVER_TEST_REWRITE_DIR:-}" ]; then
    printf '%%PDF-1.4 changed report password=UNSCANNED\n' > "$FM_DELIVER_TEST_REWRITE_DIR/report.pdf"
    printf '\211PNG changed plan password=UNSCANNED\n' > "$FM_DELIVER_TEST_REWRITE_DIR/plan.png"
  fi
  mkdir -p "$cap/../bucket/$3"
  cp "$2" "$cap/../bucket/$3"
fi
if [ "$1" = link ]; then
  if [ -n "${FM_DELIVER_TEST_CLOCK:-}" ]; then
    case "$2" in
      */report.pdf) echo '2030-11-01T00:01:00+00:00' ;;
      */plan.png) echo '2030-11-02T00:01:00+00:00' ;;
    esac > "$FM_DELIVER_TEST_CLOCK"
  fi
  echo "rclone notice"
  echo "https://share.example.net/signed/$2?X-Amz-Signature=fake"
  echo
fi
SH
chmod +x "$SHARE"
DELIVER="$BIN/fm-deliver.sh"
CONTACTS="$ROOT/bin/fm-contacts.sh"

# new_home <name>: echo a fresh FM_HOME with a seeded contact book, a task
# folder data/report/ holding report.pdf and plan.png, and order and
# confirmation files under $TMP_ROOT/<name>-words/.
new_home() {
  local home="$TMP_ROOT/$1" words="$TMP_ROOT/$1-words"
  mkdir -p "$home/data/report" "$home/state" "$home/config" "$words"
  add_contact "$home" --id site-it-lead --name "José Pérez" --alias "el de sistemas" \
    --role "Site IT, location team" --trust external --language es \
    --email jose.perez@example.com --added-by "seed"
  add_contact "$home" --id maria-lopez --name "Maria Lopez" --role "Finance" \
    --trust internal --language en --email maria.lopez@example.org --added-by "seed"
  add_contact "$home" --id wa-only --name "Wa Only" --role "Field" \
    --trust internal --language es --whatsapp +5215512345678 --added-by "seed"
  printf '%%PDF-1.4 quarterly report\n' > "$home/data/report/report.pdf"
  printf '\211PNG\r\n\032\nplan' > "$home/data/report/plan.png"
  printf 'mándale el reporte a José\n' > "$words/order"
  printf 'Sí, envía.\n' > "$words/confirm"
  printf '%s\n' "$home"
}

add_contact() {
  local home=$1
  shift
  FM_HOME="$home" "$CONTACTS" add "$@" >/dev/null 2>"$TMP_ROOT/add-err" \
    || fail "seed: fm-contacts.sh add $* failed: $(cat "$TMP_ROOT/add-err")"
}

# deliver <home> <args...>: run the send tool in <home> with the password in
# the environment, stdout to $TMP_ROOT/out and stderr to $TMP_ROOT/err; return
# its exit code. Each call starts with an empty capture directory.
deliver() {
  local home=$1 rc
  shift
  rm -f "$CAPTURE"/*
  DELIVERY_BEFORE=$(delivery_dates)
  FM_HOME="$home" FM_MAIL_PASS="$PASS_VALUE" FM_DELIVER_TEST_CAPTURE="$CAPTURE" \
    "$DELIVER" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  rc=$?
  DELIVERY_AFTER=$(delivery_dates)
  if [ "$rc" -eq 0 ] && [ -f "$CAPTURE/share-argv" ]; then
    assert_link_dates "$home"
  fi
  return "$rc"
}

# last_log <home> <python expression over d>: one value from the last log line.
last_log() {
  python3 -I -c 'import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
d = json.loads(lines[-1])
print(eval(sys.argv[2]))' "$1/data/outbound/sends.jsonl" "$2"
}

log_lines() {
  if [ -f "$1/data/outbound/sends.jsonl" ]; then
    wc -l < "$1/data/outbound/sends.jsonl" | tr -d ' '
  else
    echo 0
  fi
}

mode_of() {
  python3 -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"
}

delivery_dates() {
  python3 -I -c 'import datetime
now = datetime.datetime.now(datetime.timezone.utc)
print(now.strftime("%Y%m%d"), (now + datetime.timedelta(days=7)).strftime("%Y-%m-%d"))'
}

assert_link_dates() {
  python3 -I - "$1/data/outbound/sends.jsonl" "$CAPTURE/share-argv" "$DELIVERY_BEFORE" "$DELIVERY_AFTER" <<'PYDATES' \
    || fail "link dates fall outside the delivery window"
import json
import sys

log, calls, before, after = sys.argv[1:]
before_day, before_expiry = before.split()
after_day, after_expiry = after.split()
with open(log, encoding='utf-8') as file:
    entry = json.loads(file.read().splitlines()[-1])
assert before_day <= entry['at'][:10].replace('-', '') <= after_day
for record in entry['files']:
    assert before_expiry <= record['link_expires'] <= after_expiry
with open(calls, encoding='utf-8') as file:
    for line in file:
        if line.startswith('copy '):
            day = line.split()[-1].split('/')[1]
            assert before_day <= day <= after_day
PYDATES
}

link_folder() {
  local digest day
  digest=$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$3")
  day=$(awk -v ordinal="$2" '$1 == "copy" && ++n == ordinal {split($NF, parts, "/"); print parts[2]}' "$CAPTURE/share-argv")
  printf 'outbound/%s/%s/%s-%s/\n' "$day" "$1" "$2" "$digest"
}

test_link_mode_sends_links() {
  local home words rc expires first_expiry other_expiry folder other_folder url
  home=$(new_home link)
  words="$TMP_ROOT/link-words"
  url="https://share.example.net/signed"
  FM_MAIL_MAX_ATTACH_BYTES=30 FM_DELIVER_SHARE_CMD="$SHARE" deliver "$home" site-it-lead \
    "$home/data/report/report.pdf" "$home/data/report/plan.png" \
    --order-file "$words/order" --confirm-file "$words/confirm"
  rc=$?
  expect_code 0 "$rc" "files above the attachment cap go as links"
  folder=$(link_folder site-it-lead 1 "$home/data/report/report.pdf")
  other_folder=$(link_folder site-it-lead 2 "$home/data/report/plan.png")
  first_expiry=$(last_log "$home" 'd["files"][0]["link_expires"]')
  other_expiry=$(last_log "$home" 'd["files"][1]["link_expires"]')
  expires=$(last_log "$home" 'max(f["link_expires"] for f in d["files"])')
  assert_equals "sent: José Pérez email j***@example.com 2 file(s) 38 bytes by link, expires $expires" \
    "$(cat "$TMP_ROOT/out")" "the receipt says link and the expiry date"
  assert_equals "copy report.pdf $folder
link ${folder}report.pdf --expire 168h
copy plan.png $other_folder
link ${other_folder}plan.png --expire 168h" "$(cat "$CAPTURE/share-argv")" \
    "each file is uploaded to its indexed hash folder and linked for 168h"
  assert_present "$CAPTURE/share-env-arrived" "the sharing command gets the environment unchanged"
  assert_equals "send
--
jose.perez@example.com
Documento: report.pdf
-" "$(cat "$CAPTURE/argv")" "a link send attaches nothing"
  assert_equals "Le comparto los archivos en estos enlaces.

report.pdf (26 bytes): $url/${folder}report.pdf?X-Amz-Signature=fake - El enlace vence el $first_expiry.
plan.png (12 bytes): $url/${other_folder}plan.png?X-Amz-Signature=fake - El enlace vence el $other_expiry." \
    "$(cat "$CAPTURE/stdin")" "the Spanish body lists each file with its size, link, and expiry"
  assert_equals "link" "$(last_log "$home" 'd["mode"]')" "the log records the link mode"
  assert_equals "name,sha256,bytes,home,secondmate,link_expires" "$(last_log "$home" '",".join(d["files"][0])')" \
    "a link file entry holds exactly the documented fields"
  assert_equals "sent" "$(last_log "$home" 'd["result"]')" "the link send is logged as sent"
  assert_no_grep "share.example.net" "$home/data/outbound/sends.jsonl" "the log never holds the link URL"
  printf 'FM_DELIVER_SHARE_CMD=config/share.sh\nFM_MAIL_MAX_ATTACH_BYTES=20\n' > "$home/.env"
  cp "$SHARE" "$home/config/share.sh"
  deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order"
  rc=$?
  expect_code 0 "$rc" "the share command and the cap come from .env, relative to the home"
  folder=$(link_folder maria-lopez 1 "$home/data/report/report.pdf")
  expires=$(last_log "$home" 'd["files"][0]["link_expires"]')
  assert_equals "Please find the file at this link.

report.pdf (26 bytes): $url/${folder}report.pdf?X-Amz-Signature=fake - The link expires on $expires." \
    "$(cat "$CAPTURE/stdin")" "the English body has the link and the expiry sentence"
  printf 'Here is the report.\n' > "$home/data/report/note.txt"
  deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order" \
    --note-file "$home/data/report/note.txt"
  expect_code 0 "$?" "a link send with a covering note"
  folder=$(link_folder maria-lopez 1 "$home/data/report/report.pdf")
  expires=$(last_log "$home" 'd["files"][0]["link_expires"]')
  assert_equals "Here is the report.

report.pdf (26 bytes): $url/${folder}report.pdf?X-Amz-Signature=fake - The link expires on $expires." \
    "$(cat "$CAPTURE/stdin")" "the note comes before the link lines"
  FM_MAIL_MAX_ATTACH_BYTES=30 deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order"
  expect_code 0 "$?" "a set at or below the cap"
  assert_absent "$CAPTURE/share-argv" "a set below the cap never runs the sharing command"
  assert_contains "$(cat "$CAPTURE/argv")" "--attach" "a set below the cap is still attached"
  assert_equals "attachment" "$(last_log "$home" 'd["mode"]')" "a set below the cap logs the attachment mode"
  pass "fm-deliver: a set above the attachment cap goes as signed 7-day links in the body"
}

test_link_mode_needs_share_command() {
  local home words rc
  home=$(new_home linkless)
  words="$TMP_ROOT/linkless-words"
  FM_MAIL_MAX_ATTACH_BYTES=30 deliver "$home" maria-lopez "$home/data/report/report.pdf" \
    "$home/data/report/plan.png" --order-file "$words/order"
  rc=$?
  expect_code 5 "$rc" "an oversized set without a sharing command"
  assert_contains "$(cat "$TMP_ROOT/err")" "cannot go as a link because $home/config/fm-share-b2.sh is not an executable file" \
    "the refusal names the missing sharing command"
  assert_absent "$CAPTURE/argv" "an oversized set without a sharing command sends nothing"
  printf '#!/bin/sh\n' > "$TMP_ROOT/not-executable.sh"
  FM_MAIL_MAX_ATTACH_BYTES=30 FM_DELIVER_SHARE_CMD="$TMP_ROOT/not-executable.sh" deliver "$home" maria-lopez \
    "$home/data/report/report.pdf" "$home/data/report/plan.png" --order-file "$words/order"
  rc=$?
  expect_code 5 "$rc" "an oversized set with a sharing command that is not executable"
  assert_contains "$(cat "$TMP_ROOT/err")" "is not an executable file" "the refusal names the unusable sharing command"
  assert_absent "$CAPTURE/argv" "an unusable sharing command sends nothing"
  assert_equals "refused" "$(last_log "$home" 'd["result"]')" "the refusal is logged"
  cp "$SHARE" "$home/config/fm-share-b2.sh"
  python3 -I - "$home/data/report/report.pdf" <<'PYFILE'
import sys
with open(sys.argv[1], 'wb') as file:
    file.write(b'%PDF-1.4 large report\n')
    file.truncate(25 * 1048576)
PYFILE
  deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order"
  expect_code 0 "$?" "an unset override uses the executable default for a 25 MiB file"
  assert_present "$CAPTURE/share-argv" "the default wrapper uploads and signs the file"
  assert_equals "link" "$(last_log "$home" 'd["mode"]')" "the default caps allow a 25 MiB link send"
  assert_contains "$(cat "$CAPTURE/stdin")" "report.pdf (25.0 MB): https://" "the default wrapper's link reaches the body"
  FM_DELIVER_SHARE_CMD="$TMP_ROOT/not-executable.sh" deliver "$home" maria-lopez \
    "$home/data/report/report.pdf" --order-file "$words/order"
  expect_code 0 "$?" "an unusable override falls back to the executable default"
  assert_present "$CAPTURE/share-argv" "the default wrapper works when the override is unusable"
  pass "fm-deliver: link mode uses the default wrapper or refuses when neither command is executable"
}

test_link_mode_share_failure() {
  local home words rc failure expected snapshot
  home=$(new_home linkfail)
  words="$TMP_ROOT/linkfail-words"
  for failure in copy link badurl; do
    FM_DELIVER_TEST_SHARE_FAIL=$failure FM_MAIL_MAX_ATTACH_BYTES=30 FM_DELIVER_SHARE_CMD="$SHARE" \
      deliver "$home" maria-lopez "$home/data/report/report.pdf" "$home/data/report/plan.png" --order-file "$words/order"
    rc=$?
    expect_code 7 "$rc" "a failed sharing command ($failure)"
    case "$failure" in
      copy)
        expected="the sharing command failed: copy exited 3 before any mail was sent"
        assert_contains "$(cat "$TMP_ROOT/err")" "share stub: copy failed" "the sharing command's own error reaches stderr"
        ;;
      link) expected="the sharing command failed: link exited 3 before any mail was sent" ;;
      badurl) expected="link printed no https:// link for report.pdf" ;;
    esac
    assert_contains "$(cat "$TMP_ROOT/err")" "$expected" "the error names the failed step ($failure)"
    assert_absent "$CAPTURE/argv" "no mail is sent after a sharing failure ($failure)"
    assert_equals "error" "$(last_log "$home" 'd["result"]')" "the sharing failure is logged as an error ($failure)"
    assert_contains "$(last_log "$home" 'd["detail"]')" "$expected" "the log names the failed step ($failure)"
    assert_equals "link" "$(last_log "$home" 'd["mode"]')" "the failed attempt logs the link mode ($failure)"
    while IFS= read -r snapshot; do
      assert_absent "$snapshot" "a sharing failure removes the snapshot ($failure)"
      assert_absent "$(dirname "$snapshot")" "a sharing failure removes the snapshot directory ($failure)"
    done < "$CAPTURE/share-sources"
  done
  assert_no_grep "share.example.net" "$home/data/outbound/sends.jsonl" "the log never holds a printed URL"
  pass "fm-deliver: a sharing command failure exits 7, is logged, and sends no mail"
}

test_link_mode_preflight_and_dry_run() {
  local home words rc out
  home=$(new_home linkcheck)
  words="$TMP_ROOT/linkcheck-words"
  FM_MAIL_MAX_ATTACH_BYTES=30 FM_DELIVER_SHARE_CMD="$SHARE" deliver "$home" site-it-lead \
    "$home/data/report/report.pdf" "$home/data/report/plan.png" --order-file "$words/order" --dry-run
  rc=$?
  expect_code 0 "$rc" "a dry run for an oversized set"
  out=$(cat "$TMP_ROOT/out")
  case "$out" in
    *"delivery: link, expires ${DELIVERY_BEFORE#* }"*|*"delivery: link, expires ${DELIVERY_AFTER#* }"*) ;;
    *) fail "the card expiry falls outside the delivery window" ;;
  esac
  assert_contains "$out" "covering text: Le comparto los archivos en estos enlaces." "the card shows the link covering text"
  assert_absent "$CAPTURE/share-argv" "a dry run uploads nothing"
  assert_absent "$CAPTURE/argv" "a dry run sends nothing"
  assert_absent "$home/data/outbound/sends.jsonl" "a dry run writes no log line"
  printf '%%PDF-1.4 a long enough file\npassword=LEAKEDVALUE\n' > "$home/data/report/leak.pdf"
  FM_MAIL_MAX_ATTACH_BYTES=30 FM_DELIVER_SHARE_CMD="$SHARE" deliver "$home" maria-lopez \
    "$home/data/report/leak.pdf" --order-file "$words/order"
  expect_code 5 "$?" "a file above the attachment cap is still scanned"
  assert_contains "$(cat "$TMP_ROOT/err")" "matches the secret pattern password=" "the scan reads a file headed for a link"
  assert_absent "$CAPTURE/share-argv" "a preflight refusal uploads nothing"
  FM_DELIVER_MAX_BYTES=30 FM_MAIL_MAX_ATTACH_BYTES=20 FM_DELIVER_SHARE_CMD="$SHARE" deliver "$home" maria-lopez \
    "$home/data/report/report.pdf" "$home/data/report/plan.png" --order-file "$words/order"
  expect_code 5 "$?" "a link send above FM_DELIVER_MAX_BYTES"
  assert_contains "$(cat "$TMP_ROOT/err")" "above the FM_DELIVER_MAX_BYTES cap of 30 bytes" "the total cap still bounds a link send"
  assert_absent "$CAPTURE/share-argv" "a set above the total cap uploads nothing"
  pass "fm-deliver: link mode runs the preflight first, and a dry run uploads nothing"
}

test_link_destinations_preserve_content() {
  local home words first_folder second_folder replacement_folder
  home=$(new_home linkpaths)
  words="$TMP_ROOT/linkpaths-words"
  mkdir -p "$home/data/other"
  cp "$home/data/report/report.pdf" "$home/data/other/report.pdf"
  FM_MAIL_MAX_ATTACH_BYTES=30 FM_DELIVER_SHARE_CMD="$SHARE" deliver "$home" maria-lopez \
    "$home/data/report/report.pdf" "$home/data/other/report.pdf" --order-file "$words/order"
  expect_code 0 "$?" "two same-name files with identical contents can go as links"
  first_folder=$(link_folder maria-lopez 1 "$home/data/report/report.pdf")
  second_folder=$(link_folder maria-lopez 2 "$home/data/other/report.pdf")
  assert_equals "copy report.pdf $first_folder
link ${first_folder}report.pdf --expire 168h
copy report.pdf $second_folder
link ${second_folder}report.pdf --expire 168h" "$(cat "$CAPTURE/share-argv")" \
    "the file index isolates equal basenames even with equal hashes"
  assert_contains "$(cat "$CAPTURE/stdin")" "report.pdf (26 bytes): https://share.example.net/signed/${first_folder}report.pdf?" \
    "the first link keeps its displayed filename"
  assert_contains "$(cat "$CAPTURE/stdin")" "report.pdf (26 bytes): https://share.example.net/signed/${second_folder}report.pdf?" \
    "the second link keeps its displayed filename"
  assert_equals "report.pdf report.pdf" "$(last_log "$home" '" ".join(f["name"] for f in d["files"])')" \
    "the log retains both filenames"
  printf '%%PDF-1.4 replacement report with different contents\n' > "$home/data/report/report.pdf"
  FM_MAIL_MAX_ATTACH_BYTES=30 FM_DELIVER_SHARE_CMD="$SHARE" deliver "$home" maria-lopez \
    "$home/data/report/report.pdf" --order-file "$words/order"
  expect_code 0 "$?" "a later send of changed contents succeeds"
  replacement_folder=$(link_folder maria-lopez 1 "$home/data/report/report.pdf")
  assert_not_contains "$replacement_folder" "$first_folder" "changed contents get a different object path"
  cmp "$home/data/other/report.pdf" "$TMP_ROOT/bucket/${first_folder}report.pdf" \
    || fail "a later send replaced the first link's contents"
  cmp "$home/data/report/report.pdf" "$TMP_ROOT/bucket/${replacement_folder}report.pdf" \
    || fail "the later link does not serve the replacement contents"
  assert_contains "$(cat "$CAPTURE/stdin")" "https://share.example.net/signed/${replacement_folder}report.pdf?" \
    "the later message links its own uploaded contents"
  assert_equals "$(basename "${replacement_folder%/}" | cut -d- -f2)" \
    "$(last_log "$home" 'd["files"][0]["sha256"]')" "the log hash matches the linked upload"
  pass "fm-deliver: same-name files have isolated links and later sends preserve earlier contents"
}

test_link_upload_uses_scanned_bytes() {
  local home words first_folder second_folder snapshot
  home=$(new_home linksnapshot)
  words="$TMP_ROOT/linksnapshot-words"
  cp "$home/data/report/report.pdf" "$TMP_ROOT/original-report.pdf"
  cp "$home/data/report/plan.png" "$TMP_ROOT/original-plan.png"
  FM_MAIL_MAX_ATTACH_BYTES=30 FM_DELIVER_SHARE_CMD="$SHARE" deliver "$home" maria-lopez \
    "$home/data/report/report.pdf" "$home/data/report/plan.png" --order-file "$words/order"
  expect_code 0 "$?" "the original file set goes as links"
  FM_DELIVER_TEST_REWRITE_DIR="$home/data/report" FM_MAIL_MAX_ATTACH_BYTES=30 FM_DELIVER_SHARE_CMD="$SHARE" \
    deliver "$home" maria-lopez "$home/data/report/report.pdf" "$home/data/report/plan.png" --order-file "$words/order"
  expect_code 0 "$?" "source changes during copy do not change the scanned uploads"
  first_folder=$(link_folder maria-lopez 1 "$TMP_ROOT/original-report.pdf")
  second_folder=$(link_folder maria-lopez 2 "$TMP_ROOT/original-plan.png")
  assert_contains "$(cat "$home/data/report/report.pdf")" "password=UNSCANNED" "the first source changed during copy"
  assert_contains "$(cat "$home/data/report/plan.png")" "password=UNSCANNED" "a later source changed before its upload"
  cmp "$TMP_ROOT/original-report.pdf" "$TMP_ROOT/bucket/${first_folder}report.pdf" \
    || fail "the report upload differs from its scanned bytes"
  cmp "$TMP_ROOT/original-plan.png" "$TMP_ROOT/bucket/${second_folder}plan.png" \
    || fail "the later upload differs from its scanned bytes"
  assert_equals "38" "$(last_log "$home" 'sum(f["bytes"] for f in d["files"])')" "the log sizes describe the uploaded snapshots"
  assert_equals "$(basename "${first_folder%/}" | cut -d- -f2)" \
    "$(last_log "$home" 'd["files"][0]["sha256"]')" "the report hash describes the uploaded snapshot"
  assert_equals "$(basename "${second_folder%/}" | cut -d- -f2)" \
    "$(last_log "$home" 'd["files"][1]["sha256"]')" "the later hash describes the uploaded snapshot"
  assert_contains "$(cat "$CAPTURE/stdin")" "report.pdf (26 bytes):" "the report line uses the scanned size"
  assert_contains "$(cat "$CAPTURE/stdin")" "plan.png (12 bytes):" "the later line uses the scanned size"
  assert_equals "600 700
600 700" "$(cat "$CAPTURE/share-modes")" "snapshots and their directories are private"
  while IFS= read -r snapshot; do
    assert_absent "$snapshot" "a successful copy removes the snapshot"
    assert_absent "$(dirname "$snapshot")" "a successful copy removes the snapshot directory"
  done < "$CAPTURE/share-sources"
  assert_no_grep "UNSCANNED" "$home/data/outbound/sends.jsonl" "the log omits the changed source contents"
  pass "fm-deliver: uploads use private snapshots of the scanned bytes despite source changes"
}

test_link_expiry_follows_signing() {
  local home words driver clock contact expiry_sentence
  local -a clock_env
  home=$(new_home linkclock)
  words="$TMP_ROOT/linkclock-words"
  driver="$TMP_ROOT/link-clock.py"
  clock="$TMP_ROOT/link-clock"
  cat > "$driver" <<'PYCLOCK'
import datetime
import os
import pathlib
import runpy
import sys
from unittest.mock import patch

class Clock(datetime.datetime):
    @classmethod
    def now(cls, tz=None):
        return cls.fromisoformat(pathlib.Path(os.environ['FM_DELIVER_TEST_CLOCK']).read_text().strip()).astimezone(tz)

script, *args = sys.argv[1:]
sys.argv = [script, *args]
with patch.object(datetime, 'datetime', Clock):
    runpy.run_path(script, run_name='__main__')
PYCLOCK
  clock_env=(
    "FM_DELIVER_HOME=$home" "FM_DELIVER_DATA=$home/data" "FM_DELIVER_AWAY="
    "FM_DELIVER_MAIL=$BIN/fm-mail.sh" "FM_DELIVER_CONTACTS_PY=$ROOT/bin/fm-contacts.py"
    "FM_DELIVER_SHARE_CMD=$SHARE" "FM_MAIL_MAX_ATTACH_BYTES=30"
    "FM_DELIVER_TEST_CAPTURE=$CAPTURE" "FM_DELIVER_TEST_CLOCK=$clock"
  )
  for contact in maria-lopez site-it-lead; do
    rm -f "$CAPTURE"/*
    echo '2030-10-31T23:59:00+00:00' > "$clock"
    env "${clock_env[@]}" python3 -I "$driver" "$ROOT/bin/fm-deliver.py" "$contact" \
      "$home/data/report/report.pdf" "$home/data/report/plan.png" \
      --order-file "$words/order" --dry-run > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"
    expect_code 0 "$?" "a dry run before midnight ($contact)"
    assert_contains "$(cat "$TMP_ROOT/out")" "delivery: link, expires 2030-11-07" "the dry-run card shows the planned expiry"
    assert_absent "$CAPTURE/share-argv" "a dry run does not sign links"
    env "${clock_env[@]}" python3 -I "$driver" "$ROOT/bin/fm-deliver.py" "$contact" \
      "$home/data/report/report.pdf" "$home/data/report/plan.png" \
      --order-file "$words/order" --confirm-file "$words/confirm" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"
    expect_code 0 "$?" "signing commands finish on different UTC dates ($contact)"
    DELIVERY_BEFORE='20301031 2030-11-07'
    DELIVERY_AFTER='20301102 2030-11-09'
    assert_link_dates "$home"
    assert_equals "2030-11-08 2030-11-09" \
      "$(last_log "$home" '" ".join(f["link_expires"] for f in d["files"])')" "each file logs its own expiry"
    expiry_sentence='The link expires on'
    [ "$contact" != site-it-lead ] || expiry_sentence='El enlace vence el'
    assert_contains "$(sed -n '3p' "$CAPTURE/stdin")" "$expiry_sentence 2030-11-08." "the report body line uses its signing date"
    assert_contains "$(sed -n '4p' "$CAPTURE/stdin")" "$expiry_sentence 2030-11-09." "the later body line uses its signing date"
    assert_contains "$(cat "$TMP_ROOT/out")" "by link, expires 2030-11-09" "the receipt uses the latest expiry"
    assert_no_grep "share.example.net" "$home/data/outbound/sends.jsonl" "the log stores dates without URLs"
  done
  pass "fm-deliver: each link expires seven days after signing and the receipt uses the latest date"
}

test_unlisted_contact_refused() {
  local home words rc
  home=$(new_home unlisted)
  words="$TMP_ROOT/unlisted-words"
  deliver "$home" nobody "$home/data/report/report.pdf" --order-file "$words/order"
  rc=$?
  expect_code 2 "$rc" "an id that is not in the book"
  assert_contains "$(cat "$TMP_ROOT/err")" "must be added first" "the refusal says the contact must be added first"
  assert_absent "$CAPTURE/argv" "an unlisted contact never reaches the mail plane"
  assert_equals "refused" "$(last_log "$home" 'd["result"]')" "the refusal is logged"
  deliver "$home" jose.perez@example.com "$home/data/report/report.pdf" --order-file "$words/order"
  rc=$?
  expect_code 2 "$rc" "a raw address, even a listed one, is not a contact id"
  assert_contains "$(cat "$TMP_ROOT/err")" "an address is not in the contact book" "the refusal names a raw address"
  assert_absent "$CAPTURE/argv" "a raw address never reaches the mail plane"
  pass "fm-deliver: an unlisted contact or a raw address is refused"
}

test_external_needs_confirmation() {
  local home words rc
  home=$(new_home external)
  words="$TMP_ROOT/external-words"
  deliver "$home" site-it-lead "$home/data/report/report.pdf" --order-file "$words/order"
  rc=$?
  expect_code 3 "$rc" "an external send without a confirmation"
  assert_contains "$(cat "$TMP_ROOT/err")" "the confirmation is missing" "the refusal names the missing confirmation"
  assert_absent "$CAPTURE/argv" "no mail is sent without the confirmation"
  for words_text in "OK" "sure" "no, don't send it" "Should I say send it?" "yes, send later" "please send it" "send items"; do
    printf '%s\n' "$words_text" > "$words/weak"
    deliver "$home" site-it-lead "$home/data/report/report.pdf" --order-file "$words/order" \
      --confirm-file "$words/weak"
    rc=$?
    expect_code 3 "$rc" "'$words_text' is not a confirmation"
    assert_absent "$CAPTURE/argv" "'$words_text' sends nothing"
  done
  assert_equals "refused" "$(last_log "$home" 'd["result"]')" "a refused confirmation is logged"
  assert_equals "send items" "$(last_log "$home" 'd["confirmation"]')" "the log keeps the refused words exactly"
  pass "fm-deliver: an external contact needs an accepted confirmation"
}

test_external_with_confirmation_sends() {
  local home words rc pdf_sha
  home=$(new_home confirmed)
  words="$TMP_ROOT/confirmed-words"
  deliver "$home" site-it-lead "$home/data/report/report.pdf" "$home/data/report/plan.png" \
    --order-file "$words/order" --confirm-file "$words/confirm"
  rc=$?
  expect_code 0 "$rc" "an external send with 'Sí, envía.'"
  assert_equals "sent: José Pérez email j***@example.com 2 file(s) 38 bytes" "$(cat "$TMP_ROOT/out")" \
    "the receipt names the contact, channel, masked address, files, and bytes"
  assert_equals "send
--attach
$home/data/report/report.pdf
--attach
$home/data/report/plan.png
--
jose.perez@example.com
Documento: report.pdf
-" "$(cat "$CAPTURE/argv")" "the mail plane gets each file, the address, the default subject, and a stdin body"
  assert_equals "Le comparto los archivos adjuntos.
report.pdf, plan.png" "$(cat "$CAPTURE/stdin")" "the default covering text is in the contact's language and names the files"
  assert_present "$CAPTURE/password-arrived" "the password passes through the environment unchanged"
  pdf_sha=$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' \
    "$home/data/report/report.pdf")
  assert_equals "1" "$(log_lines "$home")" "one attempt is one log line"
  assert_equals "site-it-lead" "$(last_log "$home" 'd["contact_id"]')" "the log names the contact id"
  assert_equals "email" "$(last_log "$home" 'd["channel"]')" "the log names the channel"
  assert_equals "j***@example.com" "$(last_log "$home" 'd["masked_address"]')" "the log masks the address like fm-contacts.sh list"
  assert_equals "report.pdf $pdf_sha 26" "$(last_log "$home" '" ".join(str(d["files"][0][k]) for k in ("name", "sha256", "bytes"))')" \
    "the log records each file's name, SHA-256, and size"
  assert_equals "attachment" "$(last_log "$home" 'd["mode"]')" "the log records the attachment mode"
  assert_equals "mándale el reporte a José" "$(last_log "$home" 'd["order"]')" "the log quotes the order exactly"
  assert_equals "Sí, envía." "$(last_log "$home" 'd["confirmation"]')" "the log quotes the confirmation exactly"
  assert_equals "sent" "$(last_log "$home" 'd["result"]')" "the log records the result"
  assert_equals "sent to j***@example.com (attachments: 2) message-id: <delivery-test@example.net>" "$(last_log "$home" 'd["detail"]')" \
    "the log keeps the mail plane's sent line with the address masked"
  assert_contains "$(last_log "$home" 'd["at"]')" "Z" "the log time is UTC"
  assert_equals "name,sha256,bytes,home,secondmate" "$(last_log "$home" '",".join(d["files"][0])')" \
    "an attachment file entry has no link expiry"
  assert_equals "at,contact_id,channel,masked_address,files,mode,order,confirmation,result,detail" \
    "$(last_log "$home" '",".join(d)')" "the log line holds exactly the documented fields"
  assert_no_grep "jose.perez@example.com" "$home/data/outbound/sends.jsonl" "the log never holds the full address"
  assert_no_grep "$PASS_VALUE" "$home/data/outbound/sends.jsonl" "the log never holds the password"
  assert_no_grep "Le comparto" "$home/data/outbound/sends.jsonl" "the log never holds the body"
  assert_no_grep "quarterly" "$home/data/outbound/sends.jsonl" "the log never holds file contents"
  assert_not_contains "$(cat "$TMP_ROOT/out" "$TMP_ROOT/err")" "$PASS_VALUE" "the output never holds the password"
  assert_equals "700" "$(mode_of "$home/data/outbound")" "the log folder is private"
  assert_equals "600" "$(mode_of "$home/data/outbound/sends.jsonl")" "the log file is private"
  pass "fm-deliver: an external send with a confirmation goes out, logs, and prints a receipt"
}

test_internal_sends_on_order_alone() {
  local home words rc
  home=$(new_home internal)
  words="$TMP_ROOT/internal-words"
  printf 'Quarterly numbers\nSecond line.\n' > "$home/data/report/note.txt"
  deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order" \
    --note-file "$home/data/report/note.txt"
  rc=$?
  expect_code 0 "$rc" "an internal send without a confirmation"
  assert_contains "$(cat "$TMP_ROOT/out")" "sent: Maria Lopez email m***@example.org 1 file(s) 26 bytes" "the receipt"
  assert_contains "$(cat "$CAPTURE/argv")" "Document: report.pdf" "a custom note keeps the generated subject"
  assert_equals "Quarterly numbers
Second line." "$(cat "$CAPTURE/stdin")" "--note-file is the covering text"
  assert_equals "None" "$(last_log "$home" 'd["confirmation"]')" "no confirmation is logged as null"
  deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order"
  assert_equals "Please find the file attached.
report.pdf" "$(cat "$CAPTURE/stdin")" "the English default covering text names the file"
  assert_contains "$(cat "$CAPTURE/argv")" "Document: report.pdf" "the English default subject"
  pass "fm-deliver: an internal contact needs only the order"
}

test_away_mode_refuses_unless_allowed() {
  local home words rc flag
  for flag in .afk-contract .afk; do
    home=$(new_home "away${flag}")
    words="$TMP_ROOT/away${flag}-words"
    printf 'version: 2\n' > "$home/state/$flag"
    deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order"
    rc=$?
    expect_code 4 "$rc" "a send while state/$flag exists"
    assert_contains "$(cat "$TMP_ROOT/err")" "away or quiet mode is active" "the refusal names away or quiet mode"
    assert_absent "$CAPTURE/argv" "nothing is sent while away"
    assert_equals "refused" "$(last_log "$home" 'd["result"]')" "the away refusal is logged"
    deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order" --allow-away
    rc=$?
    expect_code 0 "$rc" "--allow-away sends while state/$flag exists"
    assert_present "$CAPTURE/argv" "--allow-away reaches the mail plane"
  done
  pass "fm-deliver: away or quiet mode refuses a send unless --allow-away is passed"
}

# expect_preflight <home> <message> <file>... : the send is refused with exit 5
# and the message, and nothing reaches the mail plane.
expect_preflight() {
  local home=$1 message=$2 rc
  shift 2
  deliver "$home" maria-lopez "$@" --order-file "$TMP_ROOT/preflight-words/order"
  rc=$?
  expect_code 5 "$rc" "preflight: $message"
  assert_contains "$(cat "$TMP_ROOT/err")" "$message" "preflight names the problem: $message"
  assert_absent "$CAPTURE/argv" "preflight refusal sends nothing: $message"
  assert_equals "refused" "$(last_log "$home" 'd["result"]')" "a preflight refusal is logged: $message"
}

test_preflight_refusals() {
  local home outside pattern sample name
  home=$(new_home preflight)
  outside="$TMP_ROOT/outside"
  mkdir -p "$outside"
  printf '%%PDF-1.4\n' > "$outside/a.pdf"
  expect_preflight "$home" "is outside data/" "$outside/a.pdf"
  printf '%%PDF-1.4\n' > "$home/data/top.pdf"
  expect_preflight "$home" "bookkeeping file" "$home/data/top.pdf"
  printf '%%PDF-1.4 do not read\n' > "$home/state/secret.pdf"
  ln -s "$home/state/secret.pdf" "$home/data/report/link.pdf"
  expect_preflight "$home" "is under the home state" "$home/data/report/link.pdf"
  assert_equals "None" "$(last_log "$home" 'd["files"][0]["sha256"]')" "a file under state/ is never read or hashed"
  printf 'X=1\n' > "$home/config/x.pdf"
  ln -s "$home/config/x.pdf" "$home/data/report/cfg.pdf"
  expect_preflight "$home" "is under the home config" "$home/data/report/cfg.pdf"
  printf 'X=1\n' > "$home/.env"
  ln -s "$home/.env" "$home/data/report/env.pdf"
  expect_preflight "$home" "is under the home .env" "$home/data/report/env.pdf"
  mkdir -p "$home/data/report/projects"
  printf '%%PDF-1.4\n' > "$home/data/report/projects/p.pdf"
  expect_preflight "$home" "is under a projects folder" "$home/data/report/projects/p.pdf"
  printf 'notes\n' > "$home/data/report/notes.txt"
  expect_preflight "$home" "file type not allowed" "$home/data/report/notes.txt"
  printf '# Report\n' > "$home/data/report/report.md"
  expect_preflight "$home" "Markdown must be rendered to PDF first" "$home/data/report/report.md"
  expect_preflight "$home" "not found" "$home/data/report/missing.pdf"
  FM_DELIVER_MAX_BYTES=30 expect_preflight "$home" "above the FM_DELIVER_MAX_BYTES cap of 30 bytes" \
    "$home/data/report/report.pdf" "$home/data/report/plan.png"
  FM_DELIVER_MAX_BYTES=20 expect_preflight "$home" "above the FM_DELIVER_MAX_BYTES cap of 20 bytes" \
    "$home/data/report/report.pdf"
  assert_equals "26 None" "$(last_log "$home" '"%s %s" % (d["files"][0]["bytes"], d["files"][0]["sha256"])')" \
    "a file above the cap is sized but never read"
  FM_MAIL_MAX_ATTACH_BYTES=30 expect_preflight "$home" "cannot go as a link because $home/config/fm-share-b2.sh is not an executable file" \
    "$home/data/report/report.pdf" "$home/data/report/plan.png"
  for pattern in "private-key header|-----BEGIN RSA PRIVATE KEY-----" "ghp_ token|ghp_LEAKEDVALUE" \
    "github_pat_ token|github_pat_LEAKEDVALUE" "AKIA key id|AKIALEAKEDVALUE" "password=|password=LEAKEDVALUE" \
    "FM_MAIL_PASS|FM_MAIL_PASS=LEAKEDVALUE" "Slack token|xoxb-LEAKEDVALUE" "sk- key|sk-LEAKEDVALUEabcdefghijklmn"; do
    name=${pattern%%|*}
    sample=${pattern#*|}
    printf '%%PDF-1.4\n%s\n' "$sample" > "$home/data/report/leak.pdf"
    expect_preflight "$home" "matches the secret pattern $name" "$home/data/report/leak.pdf"
    assert_not_contains "$(cat "$TMP_ROOT/out" "$TMP_ROOT/err")" "LEAKEDVALUE" "the scan never prints the matched bytes ($name)"
  done
  assert_no_grep "LEAKEDVALUE" "$home/data/outbound/sends.jsonl" "the log never holds the matched bytes"
  printf '%%PDF-1.4 sk-short\n' > "$home/data/report/short.pdf"
  deliver "$home" maria-lopez "$home/data/report/short.pdf" --order-file "$TMP_ROOT/preflight-words/order"
  expect_code 0 "$?" "sk- with fewer than 20 word characters is not a secret"
  pass "fm-deliver: the preflight refuses each unsafe file before any send"
}

# secondmate_refused <home> <message> <file>: a send of <file> is refused by
# the preflight with <message>, nothing is sent, and the file is never read.
secondmate_refused() {
  local home=$1 message=$2 file=$3
  deliver "$home" maria-lopez "$file" --order-file "$TMP_ROOT/secondmate-words/order"
  expect_code 5 "$?" "second mate preflight: $message"
  assert_contains "$(cat "$TMP_ROOT/err")" "$message" "the refusal names the problem: $message"
  assert_absent "$CAPTURE/argv" "a refused second mate file sends nothing: $message"
  assert_equals "refused None None" "$(last_log "$home" '"%s %s %s" % (d["result"], d["files"][0]["sha256"], d["files"][0]["home"])')" \
    "a refused second mate file is logged, never read, and has no home: $message"
}

test_secondmate_home_deliverables() {
  local home mate remote stranger words pdf_sha registry
  home=$(new_home secondmate)
  words="$TMP_ROOT/secondmate-words"
  mate="$TMP_ROOT/docs-mate-home"
  remote="$TMP_ROOT/far-mate-home"
  stranger="$TMP_ROOT/stranger-home"
  registry="$home/data/secondmates.md"
  mkdir -p "$mate/data/brief" "$mate/data/outbound" "$mate/config" "$mate/state" "$stranger/data/brief" "$remote/data/brief"
  printf -- '- docs-mate - Writes the documents. (home: %s; scope: documents and reports; projects: ; added 2026-10-24)\n' \
    "$mate" > "$registry"
  printf -- '- far-mate - Runs on another machine. (host: farbox; root: /srv/fm; home: %s; scope: remote work; projects: ; added 2026-10-24)\n' \
    "$remote" >> "$registry"
  printf '%%PDF-1.4 mate brief\n' > "$mate/data/brief/brief.pdf"
  printf 'The brief from the documents mate.\n' > "$mate/data/brief/note.txt"
  deliver "$home" maria-lopez "$mate/data/brief/brief.pdf" --order-file "$words/order" \
    --note-file "$mate/data/brief/note.txt"
  expect_code 0 "$?" "a file in a registered local second mate's data/<task>/"
  assert_contains "$(cat "$CAPTURE/argv")" "$mate/data/brief/brief.pdf" "the mate's file reaches the mail plane"
  assert_equals "The brief from the documents mate." "$(cat "$CAPTURE/stdin")" "a covering note from the mate's data/<task>/ is accepted"
  pdf_sha=$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' \
    "$mate/data/brief/brief.pdf")
  assert_equals "$pdf_sha $mate docs-mate" \
    "$(last_log "$home" '"%s %s %s" % (d["files"][0]["sha256"], d["files"][0]["home"], d["files"][0]["secondmate"])')" \
    "the log records the second mate home the file came from"
  assert_absent "$mate/data/outbound/sends.jsonl" "the send log stays in this home"
  deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order"
  expect_code 0 "$?" "a file in this home's data/<task>/ still sends"
  assert_equals "$home None" "$(last_log "$home" '"%s %s" % (d["files"][0]["home"], d["files"][0]["secondmate"])')" \
    "the log records this home for its own files"

  printf '%%PDF-1.4 do not read\n' > "$mate/data/outbound/old.pdf"
  secondmate_refused "$home" "is in the send log folder data/outbound/ of second mate docs-mate" "$mate/data/outbound/old.pdf"
  printf '%%PDF-1.4 do not read\n' > "$mate/config/x.pdf"
  secondmate_refused "$home" "is under the home config of second mate docs-mate" "$mate/config/x.pdf"
  ln -s "$mate/config/x.pdf" "$mate/data/brief/cfg.pdf"
  secondmate_refused "$home" "is under the home config of second mate docs-mate" "$mate/data/brief/cfg.pdf"
  printf '%%PDF-1.4 do not read\n' > "$mate/state/x.pdf"
  secondmate_refused "$home" "is under the home state of second mate docs-mate" "$mate/state/x.pdf"
  printf 'X=1\n' > "$mate/.env"
  ln -s "$mate/.env" "$mate/data/brief/env.pdf"
  secondmate_refused "$home" "is under the home .env of second mate docs-mate" "$mate/data/brief/env.pdf"
  secondmate_refused "$home" "is under the home .env of second mate docs-mate" "$mate/.env"
  printf '%%PDF-1.4 do not read\n' > "$mate/data/top.pdf"
  secondmate_refused "$home" "is a data/ bookkeeping file of second mate docs-mate" "$mate/data/top.pdf"
  printf '%%PDF-1.4 do not read\n' > "$mate/loose.pdf"
  secondmate_refused "$home" "is outside data/ of second mate docs-mate" "$mate/loose.pdf"
  printf '# Brief\n' > "$mate/data/brief/brief.md"
  deliver "$home" maria-lopez "$mate/data/brief/brief.md" --order-file "$words/order"
  expect_code 5 "$?" "a second mate's Markdown file"
  assert_contains "$(cat "$TMP_ROOT/err")" "Markdown must be rendered to PDF first" "the mate's .md file is refused like this home's"
  printf '%%PDF-1.4\npassword=LEAKEDVALUE\n' > "$mate/data/brief/leak.pdf"
  deliver "$home" maria-lopez "$mate/data/brief/leak.pdf" --order-file "$words/order"
  expect_code 5 "$?" "a secret in a second mate's file"
  assert_contains "$(cat "$TMP_ROOT/err")" "matches the secret pattern password=" "the mate's file gets the secret scan"

  printf '%%PDF-1.4 do not read\n' > "$remote/data/brief/brief.pdf"
  secondmate_refused "$home" "is outside data/ of this home and of every registered local second mate home" "$remote/data/brief/brief.pdf"
  deliver "$home" maria-lopez "$remote/data/brief/brief.pdf" --order-file "$words/order" --dry-run
  expect_code 5 "$?" "a preview refuses a remote registration's file"
  assert_contains "$(cat "$TMP_ROOT/err")" "is outside data/ of this home and of every registered local second mate home" \
    "a preview uses the ordinary outside-data refusal"
  printf 'Remote covering note.\n' > "$remote/data/brief/note.txt"
  deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order" \
    --note-file "$remote/data/brief/note.txt"
  expect_code 5 "$?" "a covering note under a remote registration's home"
  assert_contains "$(cat "$TMP_ROOT/err")" "is outside data/ of this home and of every registered local second mate home" \
    "a covering note uses the ordinary outside-data refusal"
  assert_absent "$CAPTURE/argv" "a refused remote covering note sends nothing"
  printf '%%PDF-1.4 do not read\n' > "$stranger/data/brief/brief.pdf"
  secondmate_refused "$home" "is outside data/" "$stranger/data/brief/brief.pdf"

  printf -- '- broken-mate - no route suffix\n' >> "$registry"
  secondmate_refused "$home" "the second mate registry cannot be used to check second mate homes: malformed secondmate registry entry: - broken-mate - no route suffix" \
    "$mate/data/brief/brief.pdf"
  deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order"
  expect_code 0 "$?" "an unusable registry does not block this home's own files"
  pass "fm-deliver: registered local second mate homes send from data/<task>/ under the same preflight"
}

test_dry_run_card() {
  local home words rc out
  home=$(new_home dryrun)
  words="$TMP_ROOT/dryrun-words"
  deliver "$home" site-it-lead "$home/data/report/report.pdf" "$home/data/report/plan.png" \
    --order-file "$words/order" --dry-run
  rc=$?
  expect_code 0 "$rc" "a dry run for an external contact before the confirmation"
  out=$(cat "$TMP_ROOT/out")
  assert_contains "$out" "recipient: José Pérez - Site IT, location team" "the card names the recipient and role"
  assert_not_contains "$out" "confirmation:" "the card leaves the confirmation decision to the skill"
  assert_contains "$out" "channel: email" "the card names the channel"
  assert_contains "$out" "address: j***@example.com" "the card masks the address"
  assert_contains "$out" "file: report.pdf - 26 bytes" "the card lists each file with its size"
  assert_contains "$out" "file: plan.png - 12 bytes" "the card lists every file"
  assert_contains "$out" "delivery: attachment" "the card says attachment or link"
  assert_contains "$out" "covering text: Le comparto los archivos adjuntos." "the card shows the first line of the covering text"
  assert_not_contains "$out" "jose.perez@example.com" "the card never shows the full address"
  assert_absent "$CAPTURE/argv" "a dry run sends nothing"
  assert_absent "$home/data/outbound/sends.jsonl" "a dry run writes no log line"
  deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order" --dry-run
  expect_code 0 "$?" "a dry run for a newly added internal contact"
  assert_not_contains "$(cat "$TMP_ROOT/out")" "confirmation:" "an internal card gives no trust-only verdict"
  assert_contains "$(cat "$TMP_ROOT/out")" "recipient: Maria Lopez - Finance" "the internal card retains the recipient"
  deliver "$home" site-it-lead "$home/data/report/report.md" --order-file "$words/order" --dry-run
  expect_code 5 "$?" "a dry run still runs the preflight"
  pass "fm-deliver: --dry-run prints the confirmation card without sending or logging"
}

test_mail_failure_and_channels() {
  local home words rc
  home=$(new_home failure)
  words="$TMP_ROOT/failure-words"
  FM_DELIVER_TEST_MAIL_FAIL=1 deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order"
  rc=$?
  expect_code 7 "$rc" "a failed mail plane"
  assert_equals "error" "$(last_log "$home" 'd["result"]')" "the failure is logged as an error"
  assert_contains "$(last_log "$home" 'd["detail"]')" "refused recipients: m***@example.org" "the error detail is logged with the address masked"
  assert_no_grep "maria.lopez@example.org" "$home/data/outbound/sends.jsonl" "the error log line never holds the full address"
  assert_not_contains "$(cat "$TMP_ROOT/out" "$TMP_ROOT/err")" "maria.lopez@example.org" "the error output masks the address"
  deliver "$home" wa-only "$home/data/report/report.pdf" --order-file "$words/order"
  rc=$?
  expect_code 6 "$rc" "a contact whose preferred channel is not email"
  assert_contains "$(cat "$TMP_ROOT/err")" "channel whatsapp not implemented" "the refusal names the channel"
  assert_equals "***678" "$(last_log "$home" 'd["masked_address"]')" "the channel refusal logs the masked address"
  assert_absent "$CAPTURE/argv" "an unimplemented channel sends nothing"
  pass "fm-deliver: a mail failure exits 7 and an unimplemented channel exits 6, both logged"
}

test_usage_errors() {
  local home lines rc
  home=$(new_home usage)
  deliver "$home" maria-lopez "$home/data/report/report.pdf"
  rc=$?
  expect_code 1 "$rc" "a send without --order-file"
  deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$TMP_ROOT/usage-words/order" --subject "Custom"
  expect_code 1 "$?" "the removed subject option is refused"
  assert_absent "$CAPTURE/argv" "a subject override sends nothing"
  lines=$(log_lines "$home")
  assert_equals "0" "$lines" "a usage error writes no log line"
  FM_HOME="$home" "$DELIVER" --help > "$TMP_ROOT/out" 2>&1
  expect_code 0 "$?" "--help"
  assert_contains "$(cat "$TMP_ROOT/out")" "av inject +FM_MAIL_PASS -- bin/fm-deliver.sh" "--help shows how to run a real send"
  pass "fm-deliver: usage errors exit 1 without a log line"
}

test_covering_note_preflight() {
  local home words note path expected
  home=$(new_home notes)
  words="$TMP_ROOT/notes-words"
  mkdir -p "$home/projects" "$home/data/report/state" "$home/data/outbound"
  for path in "$home/.env" "$home/config/account.txt" "$home/state/record.txt" \
    "$home/projects/readme.txt" "$words/outside.txt" "$home/data/top.txt" \
    "$home/data/outbound/note.txt" "$home/data/report/state/note.txt" \
    "$home/data/report/.env" "$home/data/report/.env.local"; do
    printf 'private covering text\n' > "$path"
    ln -sf "$path" "$home/data/report/link.txt"
    for note in "$path" "$home/data/report/link.txt"; do
      deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order" --note-file "$note"
      expect_code 5 "$?" "a forbidden covering note: $note"
      assert_absent "$CAPTURE/argv" "a forbidden covering note sends nothing"
      assert_equals "refused" "$(last_log "$home" 'd["result"]')" "a note refusal is logged"
      assert_no_grep "private covering text" "$home/data/outbound/sends.jsonl" "the log omits note contents"
    done
  done
  note="$home/data/report/note.txt"
  for expected in 'password=LEAKEDVALUE' 'ghp_LEAKEDVALUE' '-----BEGIN PRIVATE KEY-----'; do
    printf '%s\n' "$expected" > "$note"
    deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order" --note-file "$note"
    expect_code 5 "$?" "a secret in a covering note"
    assert_absent "$CAPTURE/argv" "a secret in a note sends nothing"
    assert_not_contains "$(cat "$TMP_ROOT/err")" "$expected" "the refusal omits matched bytes"
  done
  for path in empty invalid; do
    if [ "$path" = empty ]; then
      : > "$note"
    else
      printf '\377' > "$note"
    fi
    deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order" --note-file "$note"
    expect_code 5 "$?" "a $path covering note"
    assert_absent "$CAPTURE/argv" "an unusable note sends nothing"
  done
  printf 'password=LEAKEDVALUE\n' > "$note"
  deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order" --note-file "$note" --dry-run
  expect_code 5 "$?" "a dry run also scans the covering note"
  printf 'A safe covering note.\n' > "$note"
  ln -sf "$note" "$home/data/report/safe-link.txt"
  deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order" --note-file "$home/data/report/safe-link.txt"
  expect_code 0 "$?" "a safe covering note symlink"
  assert_equals "A safe covering note." "$(cat "$CAPTURE/stdin")" "the checked note becomes the body"
  FM_DELIVER_MAX_BYTES=26 deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order" --note-file "$home/data/report/report.pdf"
  expect_code 0 "$?" "a note exactly at the cap is allowed"
  printf 'This note is longer than the byte cap.\n' > "$note"
  FM_DELIVER_MAX_BYTES=26 deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order" --note-file "$note"
  expect_code 5 "$?" "a covering note above the cap"
  assert_absent "$CAPTURE/argv" "an oversized note sends nothing"
  pass "fm-deliver: covering notes pass location, content, and readability checks"
}

test_decoded_document_scan() {
  local home words ext kind expected rc
  home=$(new_home decoded)
  words="$TMP_ROOT/decoded-words"
  python3 - "$home/data/report" <<'PYDOC'
import pathlib, sys, zipfile, zlib
root = pathlib.Path(sys.argv[1])
for ext in ('docx', 'xlsx'):
    for kind in ('safe', 'leak'):
        with zipfile.ZipFile(root / (kind + '.' + ext), 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('document.xml', '<document>Safe first member</document>')
            archive.writestr('extra/content.bin', b'password=LEAKEDVALUE' if kind == 'leak' else b'Safe last member')
    (root / ('broken.' + ext)).write_bytes(b'not a ZIP archive')
for kind in ('safe', 'leak', 'broken'):
    data = b'%PDF-1.4\n'
    for index in range(2):
        text = b'password=LEAKEDVALUE' if kind == 'leak' and index else b'Safe text'
        payload = b'not deflated' if kind == 'broken' and index else zlib.compress(text)
        filter_name = b'/FlateDecode' if index == 0 else b'[/FlateDecode]'
        data += (b'%d 0 obj\n<< /Length %d /Filter ' % (index + 1, len(payload)) + filter_name
                 + b' /DecodeParms << /Predictor 1 >> >>\nstream\r\n' + payload + b'\r\nendstream\nendobj\n')
    (root / (kind + '.pdf')).write_bytes(data + b'%%EOF\n')
PYDOC
  for ext in docx xlsx pdf; do
    for kind in leak broken safe; do
      deliver "$home" maria-lopez "$home/data/report/$kind.$ext" --order-file "$words/order"
      rc=$?
      if [ "$kind" = safe ]; then
        expect_code 0 "$rc" "a safe $ext document"
        assert_present "$CAPTURE/argv" "a safe $ext document reaches the mail plane"
      else
        expect_code 5 "$rc" "a $kind $ext document"
        if [ "$kind" = leak ]; then
          expected="matches the secret pattern password="
        else
          expected="cannot decode document content"
        fi
        assert_contains "$(cat "$TMP_ROOT/err")" "$expected" "the document refusal names its cause"
        assert_absent "$CAPTURE/argv" "an unsafe $ext document sends nothing"
        assert_equals "refused" "$(last_log "$home" 'd["result"]')" "a document refusal is logged"
      fi
    done
  done
  assert_no_grep 'LEAKEDVALUE' "$home/data/outbound/sends.jsonl" "the log omits decoded secret bytes"
  pass "fm-deliver: the scan checks every archive member and PDF deflate stream"
}

test_input_failures_are_logged() {
  local home words field path expected before rc cap
  home=$(new_home logged-inputs)
  words="$TMP_ROOT/logged-inputs-words"
  for field in order confirm note; do
    for path in missing empty invalid; do
      if [ "$path" = empty ]; then
        : > "$words/$path"
        : > "$home/data/report/$path.txt"
      elif [ "$path" = invalid ]; then
        printf '\377' > "$words/$path"
        printf '\377' > "$home/data/report/$path.txt"
      fi
      before=$(log_lines "$home")
      case "$field" in
        order) deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/$path" ;;
        confirm) deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order" --confirm-file "$words/$path" ;;
        note) deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order" --note-file "$home/data/report/$path.txt" ;;
      esac
      rc=$?
      if [ "$field" = note ]; then expected=5; else expected=1; fi
      expect_code "$expected" "$rc" "an unusable $field file"
      assert_equals "$((before + 1))" "$(log_lines "$home")" "each input failure adds exactly one log line"
      assert_absent "$CAPTURE/argv" "an input failure sends nothing"
      assert_contains "$(last_log "$home" 'd["detail"]')" "$path" "the logged error identifies the failed input"
    done
  done
  for cap in invalid 0 -1; do
    before=$(log_lines "$home")
    FM_DELIVER_MAX_BYTES="$cap" deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order"
    expect_code 1 "$?" "an invalid delivery cap"
    FM_MAIL_MAX_ATTACH_BYTES="$cap" deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order"
    expect_code 1 "$?" "an invalid attachment cap"
    assert_equals "$((before + 2))" "$(log_lines "$home")" "each invalid cap adds one log line"
    assert_equals "error" "$(last_log "$home" 'd["result"]')" "an invalid cap logs an error"
    assert_absent "$CAPTURE/argv" "an invalid cap sends nothing"
  done
  pass "fm-deliver: file-read and cap errors enter the log boundary"
}

test_complete_confirmations() {
  local home words trust text
  home=$(new_home complete-confirmations)
  words="$TMP_ROOT/complete-confirmations-words"
  for trust in maria-lopez site-it-lead; do
    for text in 'YES, SEND!' 'Send it.' 'Sí, envía.'; do
      printf '%s\n' "$text" > "$words/confirm"
      deliver "$home" "$trust" "$home/data/report/report.pdf" --order-file "$words/order" --confirm-file "$words/confirm"
      expect_code 0 "$?" "an accepted complete confirmation"
      assert_present "$CAPTURE/argv" "an accepted complete confirmation sends"
      assert_equals "$text" "$(last_log "$home" 'd["confirmation"]')" "the log keeps the original confirmation"
    done
    printf 'Should I say send it?\n' > "$words/confirm"
    deliver "$home" "$trust" "$home/data/report/report.pdf" --order-file "$words/order" --confirm-file "$words/confirm"
    expect_code 3 "$?" "an in-sentence confirmation is refused for every trust level"
    assert_absent "$CAPTURE/argv" "an in-sentence confirmation sends nothing"
  done
  pass "fm-deliver: only a complete normalized confirmation permits a send"
}

test_stored_address_must_be_one_mailbox() {
  local home words mode
  home=$(new_home single-mailbox)
  words="$TMP_ROOT/single-mailbox-words"
  FM_HOME="$home" "$CONTACTS" add --id multiple --name Multiple --role Ops --trust internal \
    --language en --email 'ops@example.com,postmaster' --added-by test > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"
  expect_code 1 "$?" "the add flow refuses multiple mailboxes"
  python3 - "$home/data/contacts.json" <<'PYBOOK'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
book = json.loads(path.read_text())
next(c for c in book['contacts'] if c['id'] == 'maria-lopez')['email'] = 'ops@example.com,postmaster'
path.write_text(json.dumps(book))
PYBOOK
  for mode in preview send; do
    if [ "$mode" = preview ]; then
      deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order" --dry-run
    else
      deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order"
    fi
    expect_code 1 "$?" "$mode refuses a stored comma-separated address"
    assert_contains "$(cat "$TMP_ROOT/err")" "email must be one mailbox" "the refusal names the mailbox validation"
    assert_equals "" "$(cat "$TMP_ROOT/out")" "a malformed address produces no preview or receipt"
    assert_absent "$CAPTURE/argv" "a malformed address never reaches the mail plane"
  done
  assert_equals "error" "$(last_log "$home" 'd["result"]')" "the failed send is logged"
  assert_no_grep 'ops@example.com' "$home/data/outbound/sends.jsonl" "the error log omits the full malformed address"
  pass "fm-deliver: invalid stored mailboxes stop previews and sends"
}

test_pdf_filter_representations() {
  local home words kind representation expected rc
  home=$(new_home pdf-filters)
  words="$TMP_ROOT/pdf-filters-words"
  python3 - "$home/data/report" <<'PYPDF'
import pathlib, sys, zlib
root = pathlib.Path(sys.argv[1])
filters = {
    'name': (b'/FlateDecode', b''),
    'array': (b'[/FlateDecode]', b''),
    'indirect-name': (b'9 0 R', b'9 0 obj\n/FlateDecode\nendobj\n'),
    'indirect-array': (b'9 0 R', b'9 0 obj\n[/FlateDecode]\nendobj\n'),
    'escaped-name': (b'/Flate#44ecode', b''),
    'escaped-indirect': (b'9 0 R', b'9 0 obj\n[/Flate#44ecode]\nendobj\n'),
    'missing-object': (b'9 0 R', b''),
    'nested-reference': (b'9 0 R', b'9 0 obj\n10 0 R\nendobj\n10 0 obj\n/FlateDecode\nendobj\n'),
    'indirect-array-entry': (b'[9 0 R]', b'9 0 obj\n/FlateDecode\nendobj\n'),
    'other-filter': (b'/ASCII85Decode', b''),
    'chain': (b'[/FlateDecode /FlateDecode]', b''),
    'indirect-chain': (b'9 0 R', b'9 0 obj\n[/FlateDecode /FlateDecode]\nendobj\n'),
    'invalid-value': (b'null', b''),
    'missing-filter': (None, b''),
    'other-generation': (b'9 1 R', b'9 1 obj\n/FlateDecode\nendobj\n'),
    'nested-filter': (b'/ASCII85Decode /DecodeParms << /Filter /FlateDecode >>', b''),
}
for name, (filter_value, extra) in filters.items():
    for kind in ('safe', 'leak'):
        payload = zlib.compress(b'password=LEAKEDVALUE' if kind == 'leak' else b'Safe document')
        key = b'/Fil#74er' if name == 'escaped-name' else b'/Filter'
        field = b'' if filter_value is None else key + b' ' + filter_value
        document = (b'%%PDF-1.4\n1 0 obj\n<< /Length %d ' % len(payload) + field
                    + b' >>\nstream\n' + payload + b'\nendstream\nendobj\n' + extra + b'%%EOF\n')
        (root / (kind + '-' + name + '.pdf')).write_bytes(document)
PYPDF
  for representation in name array indirect-name indirect-array escaped-name escaped-indirect \
    missing-object nested-reference indirect-array-entry other-filter chain indirect-chain invalid-value missing-filter other-generation nested-filter; do
    for kind in safe leak; do
      deliver "$home" maria-lopez "$home/data/report/$kind-$representation.pdf" --order-file "$words/order"
      rc=$?
      case "$representation" in
        name|array|indirect-name|indirect-array|escaped-name|escaped-indirect)
          if [ "$kind" = safe ]; then
            expect_code 0 "$rc" "a safe PDF with $representation Filter"
            assert_present "$CAPTURE/argv" "a supported PDF reaches the mail plane"
            continue
          fi
          expected="matches the secret pattern password=" ;;
        *) expected="PDF stream" ;;
      esac
      expect_code 5 "$rc" "a refused $kind PDF with $representation Filter"
      assert_contains "$(cat "$TMP_ROOT/err")" "$expected" "the refusal names the stream problem"
      assert_absent "$CAPTURE/argv" "an unsafe or unsupported PDF sends nothing"
      assert_equals "refused" "$(last_log "$home" 'd["result"]')" "a PDF refusal is logged"
    done
  done
  deliver "$home" maria-lopez "$home/data/report/report.pdf" --order-file "$words/order" \
    --note-file "$home/data/report/leak-indirect-name.pdf"
  expect_code 5 "$?" "a covering note also scans an indirect PDF Filter"
  assert_contains "$(cat "$TMP_ROOT/err")" "matches the secret pattern password=" "the note scan finds the decoded secret"
  assert_absent "$CAPTURE/argv" "a leaking note sends nothing"
  deliver "$home" maria-lopez "$home/data/report/safe-missing-object.pdf" --order-file "$words/order" --dry-run
  expect_code 5 "$?" "a preview also refuses unresolved PDF filters"
  assert_no_grep 'LEAKEDVALUE' "$home/data/outbound/sends.jsonl" "the log omits decoded secret bytes"
  pass "fm-deliver: PDF filters resolve through the supported representations or refuse"
}

test_link_mode_sends_links
test_link_destinations_preserve_content
test_link_upload_uses_scanned_bytes
test_link_expiry_follows_signing
test_link_mode_needs_share_command
test_link_mode_share_failure
test_link_mode_preflight_and_dry_run
test_unlisted_contact_refused
test_external_needs_confirmation
test_external_with_confirmation_sends
test_internal_sends_on_order_alone
test_away_mode_refuses_unless_allowed
test_preflight_refusals
test_secondmate_home_deliverables
test_dry_run_card
test_mail_failure_and_channels
test_usage_errors
test_covering_note_preflight
test_decoded_document_scan
test_input_failures_are_logged
test_complete_confirmations
test_stored_address_must_be_one_mailbox
test_pdf_filter_representations

---
name: outbound-send
description: Load when the captain asks to send a file to a person, in any form such as "send it to <person>", "envía/manda <archivo> a <persona>", or "mándale <archivo> a <persona>". Owns resolving the person and the file, when a confirmation is needed and which words count, the away rule, and running bin/fm-deliver.sh.
user-invocable: false
metadata:
  internal: true
---

# Outbound send

This skill is the single owner of the confirmation rules for sending a file to a person.
[`docs/configuration.md`](../../../docs/configuration.md) "Outbound send" owns the send tool's exit codes, preflight, and send log, and "Contact book" owns the book and its resolve exit codes.

## 1. The order

These forms are the captain's order for one send: "send <file or it> to <person>", "envía <archivo> a <persona>", "manda <archivo> a <persona>", and "mándale <archivo> a <persona>", including softened forms such as "can you send it to ...".
The order is the captain's word for that one send and never becomes standing permission for a later send.
Write the captain's exact words to an order file in the session's scratch directory, never in the home or a project clone.

## 2. Resolve the person

Run `bin/fm-contacts.sh resolve <spoken words>` with the words the captain used for the person.

- Exit 0 names one contact: use its id.
- Exit 3 means the person is ambiguous: show the matches as a numbered list with name, role, and masked address, and ask the captain to choose.
- Exit 2, or an address the captain typed directly, starts the add flow: read back the name, aliases, channel, masked address, language, and trust, and run `bin/fm-contacts.sh add` only after the captain says yes, with the captain's words in `--added-by`.

Never pass an address to the send tool; it accepts only a contact id.

## 3. Resolve the file

"It", "eso", or "el archivo" means the file or files made in this conversation.
If exactly one file fits, use it.
If several fit, ask "both, or which one?" (or "¿los dos, o cuál?") and never guess.
Read every file in full before the send; never send a file you have not read.
Never send a database extract or a report that holds customer, player, or personal data, even when the preflight passes, and never send anything from `.env`, `config/`, `state/`, Vault output, or a project clone.
Render a Markdown deliverable to PDF first, because the tool refuses Markdown.

## 4. When a confirmation is needed

A send needs the captain's confirmation when any of these is true:

- The contact's trust is `external`.
- The contact was added in this send flow.
- The person or the file was ambiguous, including a choice the captain just made.

For a `self` or `internal` contact with an unambiguous person and file, the order alone is enough.

Use the rules above to decide whether a confirmation is needed; the card does not make that decision.
To collect a confirmation, run the send with `--dry-run`, show the captain the confirmation card it prints, and wait.
Only the complete normalized answer "yes, send", "send it", or "sí, envía" confirms, ignoring case, accents, and punctuation.
An answer containing additional words does not confirm.
"OK", "sure", "vale", silence, and every other answer are not a confirmation: ask again or drop the send.
Write the captain's exact confirmation words to a confirm file and pass it with `--confirm-file`, for every send that needed a confirmation, internal ones included.

## 5. Away and quiet mode

While away or quiet mode is active, no third-party send happens unless the captain's away words name that specific send.
Pass `--allow-away` only when those words name this send, or when the contact is the captain's own `self` contact, which is not a third party.
Otherwise hold the send and tell the captain at return.

## 6. Run the send

Run the real send only as `av inject +FM_MAIL_PASS -- bin/fm-deliver.sh <contact-id> <file>... --order-file <order> [--confirm-file <confirm>] [--note-file <note>]`.
The captain approves the Vault prompt for it on the phone.
Never read, print, store, or pass the password any other way.
Write a covering note, when one helps, in the contact's language under the task's deliverable folder in `data/`; without one the tool writes a short default.
The note must pass the same location checks and secret scan as attachments.

## 7. Reply

When the tool exits 0, reply to the captain with its receipt line.
When it refuses, tell the captain what it refused and why, and ask what to do.
Never work around a refusal, for example by copying a file into `data/`, renaming it, or editing it to pass the secret scan, without the captain's word.
Files above the mail attachment cap go as signed 7-day links in the mail body when the home sets a sharing command, with more Vault prompts for the captain (see "Link mode" in [Outbound send](../../../docs/configuration.md#outbound-send-dataoutboundsendsjsonl)); without one the tool refuses them.
When the mail plane fails, report the error and do not retry on your own, because the recipient may already have the message.

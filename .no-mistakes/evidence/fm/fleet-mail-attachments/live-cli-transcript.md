# Live mail evidence

The real bash bin/fm-mail.sh send command connected to a disposable loopback SMTP server using implicit TLS.
The server verified disposable app-password authentication and withheld 8BITMIME and SMTPUTF8.
The server recorded SMTP recipients and accepted message bytes. The product used no SMTP replacement or Python import hook.

The existing bash tests/fm-mail.test.sh suite passed on Apple Python 3.9.6.
Live transport checks passed on workspace-local Python 3.12.15 with OpenSSL 3.5.9.
Apple Python ignored SSL_CERT_FILE during the first setup attempt, so the first connection correctly refused the untrusted certificate.
A disposable Python runtime and process-local SSL_CERT_FILE resolved this setup problem without changing system trust.

All configuration, keys, files, runtimes, and state stayed under .mail-validation/ and were removed after testing.
No production mailbox, Vault, credential store, Herdr session, or fleet pane was accessed.

## Commands used

The complete behavioral driver is live-mail-validation.py in this evidence directory.
The driver invoked bash bin/fm-mail.sh send for each command below.
The baseline suite ran with TMPDIR=$PWD/.mail-validation/tmp, FM_TEST_SKIP_ORPHAN_REAP=1, and PYTHONDONTWRITEBYTECODE=1.
The live driver ran with .mail-validation/python/cpython-3.12.15-macos-aarch64-none/bin prepended to PATH.

## Observed CLI output and SMTP receipts

### attachments-cc-spanish

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach", ".mail-validation/files/cuestionario técnico.pdf", "--attach", ".mail-validation/files/plan.png", "--attach", ".mail-validation/files/notes.fmunknownext", "--cc", "copy-one@example.test", "--cc", "copy-two@example.test", "contact@example.test", "Cuestionario de instalación: añada sus datos", "Señora Muñoz:\nLe envío el cuestionario técnico. ¿Podría revisarlo?"]
```
Exit code: 0.

Standard output:
```text
sent to contact@example.test (attachments: 3)
```
Standard error:
```text
(empty)
```

SMTP connections: 1.
Authentication operations: 1.
MAIL transactions: 1.
DATA submissions: 1.

Received MIME message:
```json
{
  "delivered_to": [
    "contact@example.test",
    "copy-one@example.test",
    "copy-two@example.test"
  ],
  "bytes": 2535,
  "from": "Oficina Técnica Núñez <sender@example.test>",
  "to": "contact@example.test",
  "cc": "copy-one@example.test, copy-two@example.test",
  "subject": "Cuestionario de instalación: añada sus datos",
  "content_type": "multipart/mixed",
  "body": "Señora Muñoz:\nLe envío el cuestionario técnico. ¿Podría revisarlo?\n",
  "attachments": [
    {
      "filename": "cuestionario técnico.pdf",
      "content_type": "application/pdf",
      "bytes": 617,
      "sha256": "009caac265fd789d9ea869dfd6a60ba8e2dabc5bb739e110bbdef2b87084548d",
      "matches_original_bytes": true
    },
    {
      "filename": "plan.png",
      "content_type": "image/png",
      "bytes": 68,
      "sha256": "f3c9f75f396658d0bf4922ace5bdcb54a2a61822de455e17fdf1b791793615a3",
      "matches_original_bytes": true
    },
    {
      "filename": "notes.fmunknownext",
      "content_type": "application/octet-stream",
      "bytes": 256,
      "sha256": "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880",
      "matches_original_bytes": true
    }
  ],
  "wire_7bit": true,
  "raw_message": "attachments-cc-spanish.eml"
}
```

### stdin-spanish-c-locale

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach", ".mail-validation/files/cuestionario técnico.pdf", "contact@example.test", "Cuestionario de instalación: añada sus datos", "-"]
```
Exit code: 0.

Standard output:
```text
sent to contact@example.test (attachments: 1)
```
Standard error:
```text
(empty)
```

SMTP connections: 1.
Authentication operations: 1.
MAIL transactions: 1.
DATA submissions: 1.

Received MIME message:
```json
{
  "delivered_to": [
    "contact@example.test"
  ],
  "bytes": 1626,
  "from": "Nombre del entorno <sender@example.test>",
  "to": "contact@example.test",
  "cc": null,
  "subject": "Cuestionario de instalación: añada sus datos",
  "content_type": "multipart/mixed",
  "body": "Señora Muñoz:\nLe envío el cuestionario técnico. ¿Podría revisarlo?\n",
  "attachments": [
    {
      "filename": "cuestionario técnico.pdf",
      "content_type": "application/pdf",
      "bytes": 617,
      "sha256": "009caac265fd789d9ea869dfd6a60ba8e2dabc5bb739e110bbdef2b87084548d",
      "matches_original_bytes": true
    }
  ],
  "wire_7bit": true,
  "raw_message": "stdin-spanish-c-locale.eml"
}
```

### plain-positional-compatibility

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--", "contact@example.test", "-dash subject", "plain body"]
```
Exit code: 0.

Standard output:
```text
sent to contact@example.test (attachments: 0)
```
Standard error:
```text
(empty)
```

SMTP connections: 1.
Authentication operations: 1.
MAIL transactions: 1.
DATA submissions: 1.

Received MIME message:
```json
{
  "delivered_to": [
    "contact@example.test"
  ],
  "bytes": 225,
  "from": "sender@example.test",
  "to": "contact@example.test",
  "cc": null,
  "subject": "-dash subject",
  "content_type": "text/plain",
  "body": "plain body\n",
  "attachments": [],
  "wire_7bit": true,
  "raw_message": "plain-positional-compatibility.eml"
}
```

### cap-total-above

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach", ".mail-validation/files/a.bin", "--attach", ".mail-validation/files/b.bin", "contact@example.test", "Cap", "Body"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail send refused: attachments total 1100 bytes, above the FM_MAIL_MAX_ATTACH_BYTES cap of 1000 bytes
```

SMTP connections: 0.
Authentication operations: 0.
MAIL transactions: 0.
DATA submissions: 0.

### cap-total-exact

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach", ".mail-validation/files/a.bin", "--attach", ".mail-validation/files/b.bin", "contact@example.test", "Cap", "Body"]
```
Exit code: 0.

Standard output:
```text
sent to contact@example.test (attachments: 2)
```
Standard error:
```text
(empty)
```

SMTP connections: 1.
Authentication operations: 1.
MAIL transactions: 1.
DATA submissions: 1.

Received MIME message:
```json
{
  "delivered_to": [
    "contact@example.test"
  ],
  "bytes": 2261,
  "from": "sender@example.test",
  "to": "contact@example.test",
  "cc": null,
  "subject": "Cap",
  "content_type": "multipart/mixed",
  "body": "Body\n",
  "attachments": [
    {
      "filename": "a.bin",
      "content_type": "application/octet-stream",
      "bytes": 600,
      "sha256": "ba35c170729417f1499e0886e7e12fcdb4ab00ad411110ae1e888c766d4ed70d",
      "matches_original_bytes": true
    },
    {
      "filename": "b.bin",
      "content_type": "application/octet-stream",
      "bytes": 500,
      "sha256": "ba44b93823e5c24e99d64a916b3e53a97613d4c438c0c2896cadc2dd8195c14a",
      "matches_original_bytes": true
    }
  ],
  "wire_7bit": true,
  "raw_message": "cap-total-exact.eml"
}
```

### cap-default-above

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach", ".mail-validation/files/big.bin", "contact@example.test", "Default cap", "Body"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail send refused: attachments total 20971521 bytes, above the FM_MAIL_MAX_ATTACH_BYTES cap of 20971520 bytes
```

SMTP connections: 0.
Authentication operations: 0.
MAIL transactions: 0.
DATA submissions: 0.

### cap-invalid-0

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach", ".mail-validation/files/cuestionario técnico.pdf", "contact@example.test", "Bad cap", "Body"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail send refused: FM_MAIL_MAX_ATTACH_BYTES must be a positive integer, got: 0
```

SMTP connections: 0.
Authentication operations: 0.
MAIL transactions: 0.
DATA submissions: 0.

### cap-invalid-minus1

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach", ".mail-validation/files/cuestionario técnico.pdf", "contact@example.test", "Bad cap", "Body"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail send refused: FM_MAIL_MAX_ATTACH_BYTES must be a positive integer, got: -1
```

SMTP connections: 0.
Authentication operations: 0.
MAIL transactions: 0.
DATA submissions: 0.

### cap-invalid-20MB

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach", ".mail-validation/files/cuestionario técnico.pdf", "contact@example.test", "Bad cap", "Body"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail send refused: FM_MAIL_MAX_ATTACH_BYTES must be a positive integer, got: 20MB
```

SMTP connections: 0.
Authentication operations: 0.
MAIL transactions: 0.
DATA submissions: 0.

### attachment-missing

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach", ".mail-validation/files/cuestionario técnico.pdf", "--attach", ".mail-validation/files/absent.pdf", "contact@example.test", "Bad file", "Body"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail send refused: attachment not found: /Users/rega1011/.no-mistakes/worktrees/422718388d14/01M5MW75XNPRXZM6CDWSP26XMM/.mail-validation/files/absent.pdf
```

SMTP connections: 0.
Authentication operations: 0.
MAIL transactions: 0.
DATA submissions: 0.

### attachment-directory

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach", ".mail-validation/files/cuestionario técnico.pdf", "--attach", ".mail-validation/files/folder", "contact@example.test", "Bad file", "Body"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail send refused: attachment is not a regular file: /Users/rega1011/.no-mistakes/worktrees/422718388d14/01M5MW75XNPRXZM6CDWSP26XMM/.mail-validation/files/folder
```

SMTP connections: 0.
Authentication operations: 0.
MAIL transactions: 0.
DATA submissions: 0.

### attachment-fifo

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach", ".mail-validation/files/cuestionario técnico.pdf", "--attach", ".mail-validation/files/pipe.pdf", "contact@example.test", "Bad file", "Body"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail send refused: attachment is not a regular file: /Users/rega1011/.no-mistakes/worktrees/422718388d14/01M5MW75XNPRXZM6CDWSP26XMM/.mail-validation/files/pipe.pdf
```

SMTP connections: 0.
Authentication operations: 0.
MAIL transactions: 0.
DATA submissions: 0.

### attachment-unreadable

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach", ".mail-validation/files/cuestionario técnico.pdf", "--attach", ".mail-validation/files/locked.pdf", "contact@example.test", "Bad file", "Body"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail send refused: attachment unreadable: /Users/rega1011/.no-mistakes/worktrees/422718388d14/01M5MW75XNPRXZM6CDWSP26XMM/.mail-validation/files/locked.pdf
```

SMTP connections: 0.
Authentication operations: 0.
MAIL transactions: 0.
DATA submissions: 0.

### attach-missing-value

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail: --attach needs a value
fm-mail.sh read
fm-mail.sh send [--attach <path>]... [--cc <addr>]... <to> <subject> <body | ->
fm-mail.sh poll
fm-mail.sh status
```

SMTP connections: 0.
Authentication operations: 0.
MAIL transactions: 0.
DATA submissions: 0.

### cc-missing-value

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--cc"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail: --cc needs a value
fm-mail.sh read
fm-mail.sh send [--attach <path>]... [--cc <addr>]... <to> <subject> <body | ->
fm-mail.sh poll
fm-mail.sh status
```

SMTP connections: 0.
Authentication operations: 0.
MAIL transactions: 0.
DATA submissions: 0.

### unknown-option

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--bcc", "copy-one@example.test", "contact@example.test", "Bad option", "Body"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail: unknown send option: --bcc
fm-mail.sh read
fm-mail.sh send [--attach <path>]... [--cc <addr>]... <to> <subject> <body | ->
fm-mail.sh poll
fm-mail.sh status
```

SMTP connections: 0.
Authentication operations: 0.
MAIL transactions: 0.
DATA submissions: 0.

### invalid-utf8-stdin

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "contact@example.test", "Body encoding", "-"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail send refused: body is not valid UTF-8
```

SMTP connections: 0.
Authentication operations: 0.
MAIL transactions: 0.
DATA submissions: 0.

### reject-to

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach", ".mail-validation/files/cuestionario técnico.pdf", "--cc", "copy-one@example.test", "--cc", "copy-two@example.test", "contact@example.test", "Refusal", "Body"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail send refused recipients: contact@example.test
```

SMTP connections: 1.
Authentication operations: 1.
MAIL transactions: 1.
DATA submissions: 1.

Received MIME message:
```json
{
  "delivered_to": [
    "copy-one@example.test",
    "copy-two@example.test"
  ],
  "bytes": 1489,
  "from": "sender@example.test",
  "to": "contact@example.test",
  "cc": "copy-one@example.test, copy-two@example.test",
  "subject": "Refusal",
  "content_type": "multipart/mixed",
  "body": "Body\n",
  "attachments": [
    {
      "filename": "cuestionario técnico.pdf",
      "content_type": "application/pdf",
      "bytes": 617,
      "sha256": "009caac265fd789d9ea869dfd6a60ba8e2dabc5bb739e110bbdef2b87084548d",
      "matches_original_bytes": true
    }
  ],
  "wire_7bit": true,
  "raw_message": "reject-to.eml"
}
```

### reject-cc

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach", ".mail-validation/files/cuestionario técnico.pdf", "--cc", "copy-one@example.test", "--cc", "copy-two@example.test", "contact@example.test", "Refusal", "Body"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail send refused recipients: copy-one@example.test
```

SMTP connections: 1.
Authentication operations: 1.
MAIL transactions: 1.
DATA submissions: 1.

Received MIME message:
```json
{
  "delivered_to": [
    "contact@example.test",
    "copy-two@example.test"
  ],
  "bytes": 1489,
  "from": "sender@example.test",
  "to": "contact@example.test",
  "cc": "copy-one@example.test, copy-two@example.test",
  "subject": "Refusal",
  "content_type": "multipart/mixed",
  "body": "Body\n",
  "attachments": [
    {
      "filename": "cuestionario técnico.pdf",
      "content_type": "application/pdf",
      "bytes": 617,
      "sha256": "009caac265fd789d9ea869dfd6a60ba8e2dabc5bb739e110bbdef2b87084548d",
      "matches_original_bytes": true
    }
  ],
  "wire_7bit": true,
  "raw_message": "reject-cc.eml"
}
```

### reject-both-copies

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach", ".mail-validation/files/cuestionario técnico.pdf", "--cc", "copy-one@example.test", "--cc", "copy-two@example.test", "contact@example.test", "Refusal", "Body"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail send refused recipients: copy-one@example.test, copy-two@example.test
```

SMTP connections: 1.
Authentication operations: 1.
MAIL transactions: 1.
DATA submissions: 1.

Received MIME message:
```json
{
  "delivered_to": [
    "contact@example.test"
  ],
  "bytes": 1489,
  "from": "sender@example.test",
  "to": "contact@example.test",
  "cc": "copy-one@example.test, copy-two@example.test",
  "subject": "Refusal",
  "content_type": "multipart/mixed",
  "body": "Body\n",
  "attachments": [
    {
      "filename": "cuestionario técnico.pdf",
      "content_type": "application/pdf",
      "bytes": 617,
      "sha256": "009caac265fd789d9ea869dfd6a60ba8e2dabc5bb739e110bbdef2b87084548d",
      "matches_original_bytes": true
    }
  ],
  "wire_7bit": true,
  "raw_message": "reject-both-copies.eml"
}
```

### reject-all

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "--attach", ".mail-validation/files/cuestionario técnico.pdf", "--cc", "copy-one@example.test", "--cc", "copy-two@example.test", "contact@example.test", "Refusal", "Body"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail send refused recipients: contact@example.test, copy-one@example.test, copy-two@example.test
```

SMTP connections: 1.
Authentication operations: 1.
MAIL transactions: 1.
DATA submissions: 0.

### reject-sole-recipient

Command arguments:
```json
["bash", "bin/fm-mail.sh", "send", "contact@example.test", "Refusal", "Body"]
```
Exit code: 1.

Standard output:
```text
(empty)
```
Standard error:
```text
fm-mail send refused recipients: contact@example.test
```

SMTP connections: 1.
Authentication operations: 1.
MAIL transactions: 1.
DATA submissions: 0.

The JSON evidence contains the complete SMTP event trace for every case.
The .eml files contain the actual accepted message bytes, including the attachment content.

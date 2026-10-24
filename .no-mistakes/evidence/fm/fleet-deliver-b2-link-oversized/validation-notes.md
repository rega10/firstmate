# Delivery validation

The focused baseline command `bash tests/fm-deliver.test.sh` passed.
It covers the executable delivery interface, including controlled midnight expiry checks and the before/after date windows.
That suite uses simulated mail and sharing dependencies and is supplemental behavioral evidence.

The live check ran the unchanged delivery and mail commands.
A temporary home inside the worktree held only disposable contacts and documents.
A temporary sharing wrapper translated the documented copy/link interface into real rclone commands.
Real rclone v1.75.0 served an authenticated local S3 endpoint over TLS and issued signed links with a 604800-second lifetime.
A disposable TLS SMTP endpoint received the actual MIME messages.
The check fetched every signed link, compared its bytes and SHA-256, and confirmed that unsigned and tampered requests failed.
It changed both original files during upload to test snapshot safety and fetched earlier links after a changed-content send.

Apple system Python did not trust the disposable certificate through SSL_CERT_FILE.
The first live attempt therefore stopped at TLS verification.
A workspace-local Python 3.13.17 from python-build-standalone resolved that setup limitation without changing system trust.
The driver also needed corrections for the endpoint's HTTP 400 authentication refusal, fixture byte counts, note size, and SMTP CRLF formatting.
The final complete run passed without product changes.

The successful evidence-producing commands were:

```sh
mkdir -p .tmp-deliver-live
openssl req -x509 -newkey rsa:2048 -nodes -keyout .tmp-deliver-live/key.pem -out .tmp-deliver-live/cert.pem -days 2 -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1'
.tmp-deliver-python/python/bin/python3 /Users/rega1011/.no-mistakes/evidence/01M5NT0QTKZT9EZX3RGMR8DB01/live-delivery-check.py
```

The driver stopped both local services and removed the temporary home, certificates, snapshots, and bucket.
The workspace-local Python distribution was removed after verification.
No tracked files changed.

The live check did not access the operator's private wrapper, mail account, B2 bucket, Vault configuration, or credentials.
A production Vault/B2 proof requires a separately authorized disposable B2 bucket, a blessed wrapper in the disposable home, and an available Vault approval session.
The current boundary forbids access to the operator's real configuration or shared services.

The changed product surfaces are CLI output and plain-text email.
Evidence therefore consists of CLI transcripts, received MIME messages, signed-download checks, and the persisted audit log.
There is no graphical UI to capture.
The disposable URLs in the saved messages no longer work because the local services have stopped.

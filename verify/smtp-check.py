#!/usr/bin/python3
# Send one message through Postfix and check whether it was accepted or
# rejected at the end of DATA -- that's where spamass-milter's eom callback
# runs, after spamd has scored the full body.
#
#   smtp-check.py accept ham-mail.eml
#   smtp-check.py reject gtube-mail.eml

import smtplib
import sys

mode, path = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    body = f.read()

client = smtplib.SMTP("127.0.0.1", 25, timeout=30)
client.set_debuglevel(1)
try:
    client.sendmail("sender@example.net", ["recipient@example.net"], body)
    accepted, detail = True, None
except (smtplib.SMTPResponseException, smtplib.SMTPRecipientsRefused) as e:
    accepted, detail = False, e
client.quit()

if mode == "accept" and not accepted:
    print(f"expected acceptance but the message was rejected: {detail}")
    sys.exit(1)
if mode == "reject" and accepted:
    print("expected rejection but the message was accepted")
    sys.exit(1)

print(f"ok: {path} was {'accepted' if accepted else 'rejected'} as expected"
      + (f" ({detail})" if detail else ""))

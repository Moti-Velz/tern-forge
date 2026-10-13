#!/usr/bin/env python3
"""IMAP helper for the email source (lib/sources/email.luau). Python standard library only.

Reads one JSON request on stdin and prints one JSON answer:

  {"op": "list", "user", "password", "host", "port", "tls", "cursor"?}
      -> {"notes": [thread...], "cursor": "30"|null}
  {"op": "thread", "user", "password", "host", "port", "tls", "uids": [..]}
      -> {"note": thread with summary_markdown}
  any failure -> {"error": "..."}

Mailboxes are opened read-only (EXAMINE) and bodies fetched with BODY.PEEK, so nothing is marked as
read. On Gmail, "All Mail" is used and messages are grouped by Gmail's thread id; elsewhere INBOX,
grouped by subject.
"""
import email, email.header, email.policy, email.utils, html, imaplib, json, re, socket, sys
from datetime import datetime, timedelta, timezone

DAYS = 45          # how far back the list looks
SCAN = 250         # newest messages read for the list
PAGE = 30          # threads per page
BODY_CAP = 6000    # characters kept per message body

HEADERS = "FROM TO CC SUBJECT DATE MESSAGE-ID"


def connect(req):
    socket.setdefaulttimeout(30)
    cls = imaplib.IMAP4_SSL if req.get("tls", True) else imaplib.IMAP4
    m = cls(req["host"], int(req["port"]))
    m.login(req["user"], req["password"])
    gmail = "X-GM-EXT-1" in m.capabilities
    box = "INBOX"
    if gmail:
        typ, rows = m.list()
        for row in rows or []:
            line = row.decode(errors="replace")
            if "\\All" in line:
                box = line.rsplit(' "/" ', 1)[-1].strip()
                break
    typ, _ = m.select(box if box.startswith('"') else f'"{box}"', readonly=True)
    if typ != "OK":
        m.select("INBOX", readonly=True)
    return m, gmail


def decode_header(v):
    if not v:
        return ""
    try:
        return str(email.header.make_header(email.header.decode_header(v)))
    except Exception:
        return v


def people(*values):
    out = []
    for name, addr in email.utils.getaddresses([decode_header(v) for v in values if v]):
        if addr:
            out.append({"name": name or None, "email": addr.lower()})
    return out


def iso(date_value):
    try:
        d = email.utils.parsedate_to_datetime(date_value)
        if d.tzinfo is None:
            d = d.replace(tzinfo=timezone.utc)
        return d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        return None


def norm_subject(s):
    s = (s or "").strip()
    while True:
        t = re.sub(r"^\s*(re|fw|fwd|aw|tr|sv)\s*(\[\d+\])?\s*:\s*", "", s, flags=re.I)
        if t == s:
            return s.lower()
        s = t


def fetch(m, uids, items):
    """[(uid, gm_thrid, bytes)] for `items`, one UID FETCH."""
    typ, data = m.uid("FETCH", ",".join(uids), items)
    out = []
    for part in data or []:
        if not isinstance(part, tuple):
            continue
        meta = part[0].decode(errors="replace")
        uid = re.search(r"UID (\d+)", meta)
        thr = re.search(r"X-GM-THRID (\d+)", meta)
        if uid:
            out.append((uid.group(1), thr.group(1) if thr else None, part[1]))
    return out


def op_list(req):
    m, gmail = connect(req)
    if gmail:
        typ, data = m.uid("SEARCH", "X-GM-RAW", f'"newer_than:{DAYS}d -in:spam -in:trash -in:chats"')
    else:
        since = (datetime.now() - timedelta(days=DAYS)).strftime("%d-%b-%Y")
        typ, data = m.uid("SEARCH", "SINCE", since)
    uids = (data[0] or b"").decode().split()[-SCAN:]
    threads = {}
    if uids:
        items = f"(UID{' X-GM-THRID' if gmail else ''} BODY.PEEK[HEADER.FIELDS ({HEADERS})])"
        for uid, thr, raw in fetch(m, uids, items):
            msg = email.message_from_bytes(raw)
            subject = decode_header(msg.get("Subject")) or "(no subject)"
            key = thr or norm_subject(subject)
            t = threads.setdefault(key, {"uids": [], "subject": subject, "when": None, "people": {}, "thrid": thr})
            t["uids"].append(uid)
            when = iso(msg.get("Date"))
            if when and (t["when"] is None or when > t["when"]):
                t["when"] = when
            if len(t["uids"]) == 1 or not norm_subject(t["subject"]):
                t["subject"] = subject
            for p in people(msg.get("From"), msg.get("To"), msg.get("Cc")):
                t["people"].setdefault(p["email"], p)
    m.logout()
    ordered = sorted(threads.values(), key=lambda t: t["when"] or "", reverse=True)
    start = int(req.get("cursor") or 0)
    page = ordered[start:start + PAGE]
    notes = []
    for t in page:
        subject = re.sub(r"^\s*((re|fw|fwd)\s*:\s*)+", "", t["subject"], flags=re.I) or t["subject"]
        notes.append({
            "id": "email:" + "+".join(sorted(t["uids"], key=int)),
            "source": "email",
            "title": subject + (f" ({len(t['uids'])})" if len(t["uids"]) > 1 else ""),
            "created_at": t["when"],
            "attendees": list(t["people"].values()),
            "web_url": f"https://mail.google.com/mail/u/0/#all/{int(t['thrid']):x}" if t["thrid"] else None,
        })
    nxt = start + PAGE
    return {"notes": notes, "cursor": str(nxt) if nxt < len(ordered) else None}


def text_of(msg):
    """The readable text of a message: text/plain, else HTML stripped of tags."""
    plain, rich = None, None
    for part in msg.walk() if msg.is_multipart() else [msg]:
        if part.is_multipart() or part.get_content_disposition() == "attachment":
            continue
        ctype = part.get_content_type()
        try:
            content = part.get_content()
        except Exception:
            payload = part.get_payload(decode=True) or b""
            content = payload.decode(part.get_content_charset() or "utf-8", errors="replace")
        if ctype == "text/plain" and plain is None:
            plain = content
        elif ctype == "text/html" and rich is None:
            rich = content
    if plain is None and rich is not None:
        s = re.sub(r"(?is)<(script|style|head).*?</\1>", "", rich)
        s = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</h\d>|</li>|</tr>", "\n", s)
        s = re.sub(r"<[^>]+>", "", s)
        plain = html.unescape(s)
    return plain or ""


def strip_quotes(text):
    """Drops the quoted history replies carry, which the thread already has."""
    out = []
    for line in text.replace("\r\n", "\n").split("\n"):
        if re.match(r"^\s*On .{5,200}wrote:\s*$", line) or re.match(r"^\s*-{2,}\s*Original Message\s*-{2,}", line, re.I):
            break
        if re.match(r"^\s*(From|De|Von): .+", line) and out and out[-1].strip() == "":
            break
        if line.startswith(">"):
            continue
        out.append(line.rstrip())
    s = re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip()
    return s if len(s) <= BODY_CAP else s[:BODY_CAP].rstrip() + "\n\n[… truncated]"


def op_thread(req):
    m, gmail = connect(req)
    items = f"(UID{' X-GM-THRID' if gmail else ''} BODY.PEEK[])"
    got = fetch(m, [str(u) for u in req["uids"]], items)
    m.logout()
    msgs = []
    for uid, thr, raw in got:
        msg = email.message_from_bytes(raw, policy=email.policy.default)
        msgs.append((iso(msg.get("Date")) or "", msg, thr))
    if not msgs:
        return {"error": "Those messages are gone from the mailbox."}
    msgs.sort(key=lambda x: x[0])
    everyone, parts = {}, []
    for when, msg, _ in msgs:
        sender = people(msg.get("From"))
        for p in people(msg.get("From"), msg.get("To"), msg.get("Cc")):
            everyone.setdefault(p["email"], p)
        who = (sender[0]["name"] or sender[0]["email"]) if sender else "Unknown"
        attach = [p.get_filename() for p in msg.walk() if p.get_content_disposition() == "attachment" and p.get_filename()]
        body = strip_quotes(text_of(msg))
        block = f"#### {who} · {when.replace('T', ' ').replace('Z', ' UTC')}\n\n{body}"
        if attach:
            block += "\n\nAttachments: " + ", ".join(attach)
        parts.append(block)
    first, thr = msgs[0][1], msgs[-1][2]
    subject = re.sub(r"^\s*((re|fw|fwd)\s*:\s*)+", "", decode_header(first.get("Subject")) or "(no subject)", flags=re.I)
    return {"note": {
        "id": "email:" + "+".join(str(u) for u in sorted(req["uids"], key=int)),
        "source": "email",
        "title": subject,
        "created_at": msgs[-1][0] or None,
        "attendees": list(everyone.values()),
        "web_url": f"https://mail.google.com/mail/u/0/#all/{int(thr):x}" if thr else None,
        "summary_markdown": "\n\n".join(parts),
    }}


def main():
    try:
        req = json.loads(sys.stdin.read())
        res = op_list(req) if req["op"] == "list" else op_thread(req)
    except imaplib.IMAP4.error as e:
        msg = str(e)
        if "AUTHENTICATIONFAILED" in msg.upper() or "invalid credentials" in msg.lower() or "LOGIN" in msg.upper():
            msg = "The mail server rejected the address or app password (401). Connect it again."
        res = {"error": "IMAP: " + msg}
    except (OSError, socket.timeout) as e:
        res = {"error": f"Can't reach the mail server: {e}"}
    except Exception as e:
        res = {"error": f"{type(e).__name__}: {e}"}
    print(json.dumps(res, ensure_ascii=False))


if __name__ == "__main__":
    main()

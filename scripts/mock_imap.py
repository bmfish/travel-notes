#!/usr/bin/env python3
"""本地 mock IMAP 服务器:验证 App 的 IMAP 客户端端到端流程(无 TLS,仅本机测试)"""
import socket
import base64
import threading

HTML = """<html><body>
<div>您已成功购买以下车票:</div>
<table>
<tr><td>乘车日期</td><td>2026年10月07日</td></tr>
<tr><td>车次</td><td>G4098</td></tr>
<tr><td>出发/到达</td><td>郑州东 — 上海虹桥</td></tr>
<tr><td>开车时刻</td><td>20:48开</td></tr>
<tr><td>座位</td><td>05车04B号 二等座</td></tr>
<tr><td>票价</td><td>¥553.0元</td></tr>
<tr><td>乘车人</td><td>测试用户</td></tr>
</table>
<div>更多信息仅供参考,实际以车站公告为准。</div>
</body></html>"""

SUBJECT_B64 = base64.b64encode("您的订票信息".encode("utf-8")).decode()
BODY_B64 = base64.b64encode(HTML.encode("utf-8")).decode()

RAW = (
    "Message-ID: <mock-001@mock.local>\n"
    "Date: Sun, 27 Sep 2026 08:00:00 +0800\n"
    "From: 12306@12306.cn\n"
    "To: test@qq.com\n"
    f"Subject: =?UTF-8?B?{SUBJECT_B64}?=\n"
    "MIME-Version: 1.0\n"
    "Content-Type: text/html; charset=\"utf-8\"\n"
    "Content-Transfer-Encoding: base64\n"
    "\n"
    f"{BODY_B64}\n"
).replace("\n", "\r\n")


def handle(conn):
    f = conn.makefile("rb")

    def send(s):
        conn.sendall(s.encode())

    send("* OK Mock IMAP4rev1 server ready\r\n")
    for line in f:
        text = line.decode("utf-8", "replace").rstrip("\r\n")
        parts = text.split(" ")
        if not parts:
            continue
        tag, cmd = parts[0], " ".join(parts[1:]).upper()
        print("C:", text, flush=True)
        if cmd.startswith("ID"):
            send('* ID ("name" "Mock" "version" "1.0")\r\n')
            send(f"{tag} OK ID completed\r\n")
        elif cmd.startswith("LOGIN"):
            send(f"{tag} OK LOGIN completed\r\n")
        elif cmd.startswith("SELECT"):
            send("* 1 EXISTS\r\n* 0 RECENT\r\n")
            send(f"{tag} OK [READ-WRITE] SELECT completed\r\n")
        elif cmd.startswith("UID SEARCH"):
            send("* SEARCH 101\r\n")
            send(f"{tag} OK SEARCH completed\r\n")
        elif cmd.startswith("UID FETCH"):
            uid = parts[2]
            send(f"* 1 FETCH (UID {uid} BODY[] {{{len(RAW)}}}\r\n")
            conn.sendall(RAW.encode())
            send(")\r\n")
            send(f"{tag} OK FETCH completed\r\n")
        elif cmd.startswith("LOGOUT"):
            send("* BYE mock\r\n")
            send(f"{tag} OK LOGOUT completed\r\n")
            break
        else:
            send(f"{tag} OK {cmd.split(' ')[0]} completed\r\n")
    conn.close()


def main():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 8025))
    s.listen(4)
    print("mock imap listening on 127.0.0.1:8025", flush=True)
    while True:
        c, addr = s.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""本地 mock IMAP 服务器:端到端验证同步流程(无 TLS,仅本机测试)

    python3 scripts/mock_imap.py                 # 正常模式
    ABORT_FIRST_FETCH=1 python3 scripts/mock_imap.py   # 首条 FETCH 用 RST 掐断,验证自动重连

内置数据(配合 App 的 -MailSyncTest 自检,E2EPASS/E2EFAIL 给结论):
  INBOX/101   2026 新版购票通知  G4098 郑州东→上海虹桥(HTML+base64 UTF-8)
  INBOX/102   12306 营销邮件     C1234 武汉—汉口(必须被广告过滤挡住)
  归档/201    2013 老版购票通知  T164 上海一郑州(GB2312+base64,无年份日期,
              charset 参数带空格/怪大小写,主题 GB2312 编码)
"""
import base64
import os
import socket
import struct

# ABORT_FIRST_FETCH=1:第一条 BODY 全文 FETCH 时用 RST 掐断连接,模拟移动网络被掐线
ABORT_FIRST_FETCH = os.environ.get("ABORT_FIRST_FETCH") == "1"
_abort_done = False


def gb2312_b64(s):
    return base64.b64encode(s.encode("gb2312")).decode()


def utf8_b64(s):
    return base64.b64encode(s.encode("utf-8")).decode()


def make_raw(message_id, date, sender, subject_enc, content_type, cte, body_raw):
    header = (
        f"Message-ID: <{message_id}>\r\n"
        f"Date: {date}\r\n"
        f"From: {sender}\r\n"
        "To: test@qq.com\r\n"
        f"Subject: {subject_enc}\r\n"
        "MIME-Version: 1.0\r\n"
        f"Content-Type: {content_type}\r\n"
        f"Content-Transfer-Encoding: {cte}\r\n"
        "\r\n"
    )
    return header.encode() + body_raw


# 2013 老邮件正文(与用户邮箱原文一致)
OLD_BODY = (
    "尊敬张三先生：您好！您在中国铁路客户服务中心网站（http://www.12306.cn）"
    "成功购买了1张车票，票款共计128.50元。所购车票信息如下："
    "1.张三，04月29日19:36，上海一郑州，T164次列车，10车091号，硬座，票价128.50元。"
    "请尽快选择如下方式之一办理换票手续后进站乘车："
    "方式一：请持购票时所使用的二代居民身份证原件到车站自动售票机换取纸质车票。"
    "方式二：请持购票时所使用二代居民身份证原件到车站售票窗口或铁路客票代售点换取纸质车票。"
    "方式三：在铁路客票代售点或自动售票机换取纸质车票时，"
    "如果购票时所使用的二代居民身份证不能识读，"
    "请持该二代居民身份证原件和订单号码E757718715到车站售票窗口换取纸质车票。"
    "温馨提示：请尽快换取纸质车票。"
)

HTML = """<html><body>
<div>您已成功购买以下车票:</div>
<table>
<tr><td>乘车日期</td><td>2026年10月07日</td></tr>
<tr><td>车次</td><td>G4098</td></tr>
<tr><td>出发/到达</td><td>郑州东 — 上海虹桥</td></tr>
<tr><td>开车时刻</td><td>20:48开</td></tr>
<tr><td>座位</td><td>05车04B号 二等座</td></tr>
<tr><td>票价</td><td>¥553.0元</td></tr>
<tr><td>乘车人</td><td>张三</td></tr>
</table>
<div>更多信息仅供参考,实际以车站公告为准。</div>
</body></html>"""

PROMO_BODY = "【铁路12306】C1234 武汉—汉口城际特惠,二等座 8.5元起,快来抢购!"

MAILS = {
    "INBOX": [
        (101, make_raw(
            "mock-101@mock.local", "Sun, 27 Sep 2026 08:00:00 +0800", "12306@12306.cn",
            "=?UTF-8?B?" + utf8_b64("您的订票信息") + "?=",
            'text/html; charset="utf-8"', "base64",
            (utf8_b64(HTML) + "\r\n").encode())),
        (102, make_raw(
            "mock-102@mock.local", "Mon, 28 Sep 2026 09:00:00 +0800", "12306@12306.cn",
            "=?UTF-8?B?" + utf8_b64("武汉—汉口城际特惠") + "?=",
            'text/plain; charset="utf-8"', "base64",
            (utf8_b64(PROMO_BODY) + "\r\n").encode())),
    ],
    "归档": [
        (201, make_raw(
            "mock-201@mock.local", "Thu, 11 Apr 2013 20:00:00 +0800", "12306<12306@rails.com.cn>",
            "=?GB2312?B?" + gb2312_b64("网上购票系统-用户支付通知") + "?=",
            'text/plain; Charset = "gb2312"', "base64",
            (gb2312_b64(OLD_BODY) + "\r\n").encode())),
    ],
}

HEADER_FIELDS = "(BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)])"


def handle(conn):
    f = conn.makefile("rb")

    def send(s):
        conn.sendall(s.encode() if isinstance(s, str) else s)

    send("* OK Mock IMAP4rev1 server ready\r\n")
    folder = "INBOX"
    for line in f:
        text = line.decode("utf-8", "replace").rstrip("\r\n")
        parts = text.split(" ")
        if not parts:
            continue
        tag, rest = parts[0], " ".join(parts[1:])
        up = rest.upper()
        print("C:", text, flush=True)
        if up.startswith("ID"):
            send('* ID ("name" "Mock" "version" "1.0")\r\n')
            send(f"{tag} OK ID completed\r\n")
        elif up.startswith("LOGIN"):
            send(f"{tag} OK LOGIN completed\r\n")
        elif up.startswith("LIST"):
            send('* LIST () "/" "INBOX"\r\n')
            send('* LIST () "/" "归档"\r\n')
            send(f"{tag} OK LIST completed\r\n")
        elif up.startswith("SELECT"):
            for name in MAILS:
                if name in rest:
                    folder = name
                    break
            send(f"* {len(MAILS[folder])} EXISTS\r\n* 0 RECENT\r\n")
            send(f"{tag} OK [READ-WRITE] SELECT completed\r\n")
        elif up.startswith("UID SEARCH"):
            uids = " ".join(str(u) for u, _ in MAILS[folder])
            send(f"* SEARCH {uids}\r\n")
            send(f"{tag} OK SEARCH completed\r\n")
        elif up.startswith("UID FETCH"):
            global _abort_done
            spec = rest[len("UID FETCH "):]
            uid_part, paren = spec.split(" (", 1)
            paren = "(" + paren
            mails = MAILS[folder]
            if uid_part != "1:*":
                wanted = {int(x) for x in uid_part.split(",")}
                mails = [(u, raw) for u, raw in mails if u in wanted]
            full_body = "BODY[]" in paren
            if full_body and ABORT_FIRST_FETCH and not _abort_done:
                _abort_done = True
                print("!! aborting connection mid-FETCH (simulated)", flush=True)
                conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                conn.close()
                return
            for seq, (uid, raw) in enumerate(mails, start=1):
                if paren == "(UID)":
                    send(f"* {seq} FETCH (UID {uid})\r\n")
                    continue
                if full_body:
                    payload, item = raw, "BODY[]"
                else:
                    head = raw.split(b"\r\n\r\n")[0] + b"\r\n\r\n"
                    payload, item = head, "BODY[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)]"
                send(f"* {seq} FETCH (UID {uid} {item} {{{len(payload)}}}\r\n")
                conn.sendall(payload)
                send(")\r\n")
            send(f"{tag} OK FETCH completed\r\n")
        elif up.startswith("LOGOUT"):
            send(f"{tag} OK LOGOUT completed\r\n")
            return
        else:
            send(f"{tag} OK completed\r\n")


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", 8025))
    srv.listen(5)
    print("mock IMAP on 0.0.0.0:8025", flush=True)
    while True:
        conn, addr = srv.accept()
        print("client", addr, flush=True)
        try:
            handle(conn)
        except Exception as e:  # noqa: BLE001 - 测试脚本,出错打印后继续
            print("handler error:", e, flush=True)
        finally:
            try:
                conn.close()
            except OSError:
                pass


if __name__ == "__main__":
    main()

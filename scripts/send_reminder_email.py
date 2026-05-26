from __future__ import annotations

import argparse
import html
import json
import os
import socket
import smtplib
import ssl
from email.message import EmailMessage
from pathlib import Path
from urllib.parse import urlparse


REMINDER_STATUSES = {"manual_reminder", "failed", "unknown", "network_error"}
REMINDER_SITES = {"muyuan", "lpgpt"}


def load_results(result_json: Path) -> list[dict]:
    with result_json.open("r", encoding="utf-8-sig") as handle:
        data = json.load(handle)
    if not isinstance(data, list):
        raise ValueError(f"Expected a list in {result_json}")
    return data


def manual_items(results: list[dict]) -> list[dict]:
    return [
        item
        for item in results
        if item.get("name") in REMINDER_SITES and item.get("status") in REMINDER_STATUSES
    ]


def chinese_reason(reason: str) -> str:
    if reason == "Manual reminder only; site was not opened by automation.":
        return "这个站点已设置为只提醒，不由自动化打开。"
    if reason == "Chrome showed a network error page.":
        return "浏览器显示网络错误页面。"
    if reason == "Page contains a failure/login/captcha keyword.":
        return "页面出现失败、登录或验证码相关提示。"
    return reason or "需要手动确认。"


def build_plain_text(items: list[dict], report_path: Path) -> str:
    lines = [
        "公益站签到提醒",
        "",
        "以下站点需要手动处理：",
        "",
    ]
    for index, item in enumerate(items, start=1):
        lines.extend(
            [
                f"{index}. {item.get('name', '')}",
                f"   状态：{item.get('status', '')}",
                f"   地址：{item.get('finalUrl') or item.get('url') or ''}",
                f"   原因：{chinese_reason(str(item.get('reason') or ''))}",
                f"   截图：{item.get('screenshot') or '无'}",
                "",
            ]
        )
    lines.extend(["报告路径：", str(report_path)])
    return "\n".join(lines)


def site_card(item: dict) -> str:
    name = html.escape(str(item.get("name") or ""))
    status = html.escape(str(item.get("status") or ""))
    url = html.escape(str(item.get("finalUrl") or item.get("url") or ""))
    reason = html.escape(chinese_reason(str(item.get("reason") or "")))
    screenshot = html.escape(str(item.get("screenshot") or "无"))

    return f"""
      <tr>
        <td style="padding:0 0 18px 0;">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
            style="border-collapse:separate;border-spacing:0;background:rgba(255,255,255,0.72);
            border:1px solid rgba(255,255,255,0.82);border-radius:28px;
            box-shadow:0 18px 46px rgba(25,39,70,0.10), inset 0 1px 0 rgba(255,255,255,0.86);
            backdrop-filter:blur(22px);-webkit-backdrop-filter:blur(22px);">
            <tr>
              <td style="padding:24px 28px 8px 28px;">
                <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                  <tr>
                    <td style="font-size:22px;line-height:1.25;font-weight:700;color:#1d1d1f;
                      font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','Microsoft YaHei',Arial,sans-serif;">
                      {name}
                    </td>
                    <td align="right">
                      <span style="display:inline-block;padding:6px 12px;border-radius:999px;
                        background:rgba(0,102,204,0.09);border:1px solid rgba(0,102,204,0.16);
                        color:#0a63ce;font-size:12px;font-weight:700;letter-spacing:.01em;
                        font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','Microsoft YaHei',Arial,sans-serif;">
                        {status}
                      </span>
                    </td>
                  </tr>
                </table>
              </td>
            </tr>
            <tr>
              <td style="padding:10px 28px 26px 28px;">
                <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
                  style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','Microsoft YaHei',Arial,sans-serif;
                  font-size:15px;line-height:1.75;color:#1d1d1f;">
                  <tr>
                    <td style="width:56px;color:#86868b;padding:2px 0;vertical-align:top;">地址</td>
                    <td style="padding:2px 0;"><a href="{url}" style="color:#0066cc;text-decoration:none;">{url}</a></td>
                  </tr>
                  <tr>
                    <td style="width:56px;color:#86868b;padding:2px 0;vertical-align:top;">原因</td>
                    <td style="padding:2px 0;">{reason}</td>
                  </tr>
                  <tr>
                    <td style="width:56px;color:#86868b;padding:2px 0;vertical-align:top;">截图</td>
                    <td style="padding:2px 0;">{screenshot}</td>
                  </tr>
                </table>
              </td>
            </tr>
          </table>
        </td>
      </tr>
    """


def build_html(items: list[dict], report_path: Path) -> str:
    cards = "\n".join(site_card(item) for item in items)
    escaped_report = html.escape(str(report_path))

    return f"""<!doctype html>
<html>
  <body style="margin:0;padding:0;background:#eef4fb;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
      style="border-collapse:collapse;background:
      radial-gradient(circle at 22% 12%, rgba(125,203,255,0.46), transparent 34%),
      radial-gradient(circle at 82% 6%, rgba(173,245,226,0.42), transparent 30%),
      linear-gradient(135deg,#f8fbff 0%,#eaf4ff 100%);">
      <tr>
        <td align="center" style="padding:40px 18px;">
          <table role="presentation" width="640" cellpadding="0" cellspacing="0"
            style="width:640px;max-width:100%;border-collapse:separate;border-spacing:0;
            background:rgba(255,255,255,0.54);border:1px solid rgba(255,255,255,0.82);
            border-radius:34px;box-shadow:0 28px 80px rgba(31,58,97,0.16), inset 0 1px 0 rgba(255,255,255,0.9);
            backdrop-filter:blur(26px);-webkit-backdrop-filter:blur(26px);overflow:hidden;">
            <tr>
              <td style="padding:34px 36px 16px 36px;
                font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','Microsoft YaHei',Arial,sans-serif;">
                <div style="font-size:13px;line-height:1.4;color:#6e6e73;letter-spacing:.02em;">
                  bb-browser daily check-in
                </div>
                <div style="margin-top:8px;font-size:32px;line-height:1.18;font-weight:750;color:#1d1d1f;">
                  公益站签到提醒
                </div>
                <div style="margin-top:14px;font-size:16px;line-height:1.7;color:#5f636d;max-width:520px;">
                  以下站点已进入手动提醒模式。自动化不会打开这些页面，只提醒你按需处理。
                </div>
              </td>
            </tr>
            <tr>
              <td style="padding:18px 36px 8px 36px;">
                <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
                  style="border-collapse:collapse;">
                  {cards}
                </table>
              </td>
            </tr>
            <tr>
              <td style="padding:8px 36px 36px 36px;">
                <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
                  style="border-collapse:separate;border-spacing:0;background:rgba(245,247,251,0.78);
                  border:1px solid rgba(255,255,255,0.7);border-radius:22px;">
                  <tr>
                    <td style="padding:18px 22px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','Microsoft YaHei',Arial,sans-serif;">
                      <div style="font-size:13px;color:#86868b;margin-bottom:8px;">报告路径</div>
                      <div style="font-size:13px;line-height:1.55;color:#1d1d1f;font-family:'SF Mono','Cascadia Mono',Consolas,monospace;word-break:break-all;">
                        {escaped_report}
                      </div>
                    </td>
                  </tr>
                </table>
                <div style="padding-top:18px;text-align:center;font-size:12px;line-height:1.6;color:#86868b;
                  font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','Microsoft YaHei',Arial,sans-serif;">
                  Codex automation · HTML MIME
                </div>
              </td>
            </tr>
          </table>
        </td>
      </tr>
    </table>
  </body>
</html>"""


def build_email_message(result_json: Path, mail_from: str, mail_to: str, subject: str) -> EmailMessage:
    results = load_results(result_json)
    if not results:
        raise ValueError("No check-in results found.")

    report_path = result_json.with_name("result.md")
    plain = build_plain_text(results, report_path)
    rich = build_html(results, report_path)

    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = mail_from
    message["To"] = mail_to
    message.set_content(plain)
    message.add_alternative(rich, subtype="html")
    return message


def create_http_connect_socket(proxy_url: str, host: str, port: int, timeout: int) -> socket.socket:
    parsed = urlparse(proxy_url)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError(f"Only HTTP CONNECT proxies are supported, got: {parsed.scheme}")
    if not parsed.hostname or not parsed.port:
        raise ValueError("Proxy URL must include host and port.")

    raw = socket.create_connection((parsed.hostname, parsed.port), timeout=timeout)
    request = (
        f"CONNECT {host}:{port} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Proxy-Connection: Keep-Alive\r\n\r\n"
    ).encode("ascii")
    raw.sendall(request)

    response = b""
    while b"\r\n\r\n" not in response:
        chunk = raw.recv(4096)
        if not chunk:
            break
        response += chunk
        if len(response) > 65536:
            break

    status_line = response.split(b"\r\n", 1)[0].decode("iso-8859-1", errors="replace")
    if " 200 " not in f" {status_line} ":
        raw.close()
        raise OSError(f"Proxy CONNECT failed: {status_line}")
    return raw


class HttpProxySMTP(smtplib.SMTP):
    def __init__(self, proxy_url: str, *args, **kwargs):
        self.proxy_url = proxy_url
        super().__init__(*args, **kwargs)

    def _get_socket(self, host, port, timeout):
        return create_http_connect_socket(self.proxy_url, host, port, timeout)


class HttpProxySMTPSSL(smtplib.SMTP_SSL):
    def __init__(self, proxy_url: str, *args, **kwargs):
        self.proxy_url = proxy_url
        super().__init__(*args, **kwargs)

    def _get_socket(self, host, port, timeout):
        plain = create_http_connect_socket(self.proxy_url, host, port, timeout)
        return self.context.wrap_socket(plain, server_hostname=host)


def send_smtp(
    message: EmailMessage,
    host: str,
    port: int,
    username: str,
    password: str,
    use_ssl: bool,
    proxy_url: str = "",
) -> None:
    if use_ssl:
        context = ssl.create_default_context()
        smtp_cls = HttpProxySMTPSSL if proxy_url else smtplib.SMTP_SSL
        smtp_args = (proxy_url, host, port) if proxy_url else (host, port)
        with smtp_cls(*smtp_args, context=context, timeout=45) as server:
            server.login(username, password)
            server.send_message(message)
        return

    smtp_cls = HttpProxySMTP if proxy_url else smtplib.SMTP
    smtp_args = (proxy_url, host, port) if proxy_url else (host, port)
    with smtp_cls(*smtp_args, timeout=45) as server:
        server.starttls(context=ssl.create_default_context())
        server.login(username, password)
        server.send_message(message)


def env_value(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def main() -> int:
    parser = argparse.ArgumentParser(description="Send a real HTML summary email for daily check-in results.")
    parser.add_argument("--result-json", required=True, type=Path)
    parser.add_argument("--to", default=env_value("CHECKIN_MAIL_TO"))
    parser.add_argument("--from-email", default=env_value("CHECKIN_MAIL_FROM") or env_value("CHECKIN_SMTP_USER"))
    parser.add_argument("--subject", default="公益站签到提醒：需要手动处理")
    parser.add_argument("--smtp-host", default=env_value("CHECKIN_SMTP_HOST", "smtp.gmail.com"))
    parser.add_argument("--smtp-port", type=int, default=int(env_value("CHECKIN_SMTP_PORT", "587") or "587"))
    parser.add_argument("--smtp-user", default=env_value("CHECKIN_SMTP_USER"))
    parser.add_argument("--smtp-pass", default=env_value("CHECKIN_SMTP_PASS"))
    parser.add_argument("--smtp-proxy", default=env_value("CHECKIN_SMTP_PROXY"))
    parser.add_argument("--ssl", action="store_true", default=False)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--output-eml", type=Path, default=None)
    args = parser.parse_args()

    if not args.to:
        raise SystemExit("Missing recipient. Set CHECKIN_MAIL_TO or pass --to.")
    if not args.from_email:
        raise SystemExit("Missing sender. Set CHECKIN_MAIL_FROM or CHECKIN_SMTP_USER.")

    message = build_email_message(
        result_json=args.result_json,
        mail_from=args.from_email,
        mail_to=args.to,
        subject=args.subject,
    )

    if args.dry_run:
        output = args.output_eml or args.result_json.with_name("manual-reminder-email.eml")
        output.write_bytes(bytes(message))
        print(output)
        return 0

    if not args.smtp_user or not args.smtp_pass:
        raise SystemExit("Missing SMTP credentials. Set CHECKIN_SMTP_USER and CHECKIN_SMTP_PASS.")

    send_smtp(
        message=message,
        host=args.smtp_host,
        port=args.smtp_port,
        username=args.smtp_user,
        password=args.smtp_pass,
        use_ssl=args.ssl or args.smtp_port == 465,
        proxy_url=args.smtp_proxy,
    )
    print("sent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

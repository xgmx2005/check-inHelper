import importlib.util
import json
import tempfile
from pathlib import Path


def load_module():
    module_path = Path(__file__).with_name("send_reminder_email.py")
    spec = importlib.util.spec_from_file_location("send_reminder_email", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_builds_real_html_email_without_image_attachment():
    module = load_module()

    with tempfile.TemporaryDirectory() as temp_dir:
        result_path = Path(temp_dir) / "result.json"
        result_path.write_text(
            json.dumps(
                [
                    {
                        "name": "linux.do",
                        "status": "ok",
                        "finalUrl": "https://linux.do/",
                        "reason": "Linux.do login precheck passed.",
                        "screenshot": "",
                    },
                    {
                        "name": "muyuan",
                        "status": "manual_reminder",
                        "finalUrl": "https://muyuan.do",
                        "reason": "Manual reminder only; site was not opened by automation.",
                        "screenshot": "",
                    },
                    {
                        "name": "lpgpt",
                        "status": "manual_reminder",
                        "finalUrl": "https://lpgpt.us/",
                        "reason": "Manual reminder only; site was not opened by automation.",
                        "screenshot": "",
                    },
                    {
                        "name": "newapi-linuxdo",
                        "status": "success",
                        "finalUrl": "https://newapi.linuxdo.edu.rs/console/personal",
                        "reason": "Clicked '立即签到' and a success/already-done keyword is visible.",
                        "screenshot": "",
                    },
                ],
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )

        message = module.build_email_message(
            result_json=result_path,
            mail_from="sender@example.com",
            mail_to="receiver@example.com",
            subject="公益站签到提醒：需要手动处理",
        )

    assert message.is_multipart()
    alternatives = list(message.iter_parts())
    assert alternatives[0].get_content_type() == "text/plain"
    assert alternatives[1].get_content_type() == "text/html"

    html = alternatives[1].get_content()
    assert "muyuan" in html
    assert "lpgpt" in html
    assert "manual_reminder" in html
    assert "newapi-linuxdo" in html
    assert "success" in html
    assert "linear-gradient" in html
    assert "rgba(" in html
    assert "backdrop-filter" in html
    assert "manual-reminder-card.png" not in html
    assert not any(part.get_content_type() == "image/png" for part in message.walk())


def test_builds_summary_email_without_manual_items():
    module = load_module()

    with tempfile.TemporaryDirectory() as temp_dir:
        result_path = Path(temp_dir) / "result.json"
        result_path.write_text(
            json.dumps(
                [
                    {
                        "name": "linux.do",
                        "status": "ok",
                        "finalUrl": "https://linux.do/",
                        "reason": "Linux.do login precheck passed.",
                        "screenshot": "",
                    },
                    {
                        "name": "newapi-linuxdo",
                        "status": "already_done",
                        "finalUrl": "https://newapi.linuxdo.edu.rs/console/personal",
                        "reason": "Already-done keyword is visible.",
                        "screenshot": "",
                    },
                ],
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )

        message = module.build_email_message(
            result_json=result_path,
            mail_from="sender@example.com",
            mail_to="receiver@example.com",
            subject="daily summary",
        )

    html = list(message.iter_parts())[1].get_content()
    assert "linux.do" in html
    assert "newapi-linuxdo" in html
    assert "already_done" in html


if __name__ == "__main__":
    test_builds_real_html_email_without_image_attachment()
    test_builds_summary_email_without_manual_items()
    print("reminder email tests ok")

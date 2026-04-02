import base64
from email.mime.text import MIMEText

from app.services.base import BaseGoogleService


class GmailService(BaseGoogleService):
    """Gmail API wrapper supporting multi-account usage."""

    def _get_service(self):
        return self._build_service("gmail", "v1")

    def _list_messages_sync(self, query: str = "", max_results: int = 20) -> list[dict]:
        service = self._get_service()
        results = (
            service.users()
            .messages()
            .list(userId="me", q=query, maxResults=max_results)
            .execute()
        )
        messages = results.get("messages", [])
        if not messages:
            return []

        detailed = []
        for msg in messages:
            msg_data = (
                service.users()
                .messages()
                .get(userId="me", id=msg["id"], format="metadata",
                     metadataHeaders=["From", "To", "Subject", "Date"])
                .execute()
            )
            headers = {h["name"]: h["value"] for h in msg_data.get("payload", {}).get("headers", [])}
            detailed.append({
                "id": msg_data["id"],
                "thread_id": msg_data.get("threadId", ""),
                "snippet": msg_data.get("snippet", ""),
                "from": headers.get("From", ""),
                "to": headers.get("To", ""),
                "subject": headers.get("Subject", "(no subject)"),
                "date": headers.get("Date", ""),
                "label_ids": msg_data.get("labelIds", []),
                "is_unread": "UNREAD" in msg_data.get("labelIds", []),
            })
        return detailed

    async def list_messages(self, query: str = "", max_results: int = 20) -> list[dict]:
        return await self._run_sync(self._list_messages_sync, query, max_results)

    def _get_message_sync(self, message_id: str) -> dict:
        service = self._get_service()
        msg = service.users().messages().get(userId="me", id=message_id, format="full").execute()
        headers = {h["name"]: h["value"] for h in msg.get("payload", {}).get("headers", [])}

        # Extract body
        body = ""
        payload = msg.get("payload", {})
        if "body" in payload and payload["body"].get("data"):
            body = base64.urlsafe_b64decode(payload["body"]["data"]).decode("utf-8", errors="replace")
        elif "parts" in payload:
            for part in payload["parts"]:
                if part.get("mimeType") == "text/plain" and part.get("body", {}).get("data"):
                    body = base64.urlsafe_b64decode(part["body"]["data"]).decode("utf-8", errors="replace")
                    break
                elif part.get("mimeType") == "text/html" and part.get("body", {}).get("data"):
                    body = base64.urlsafe_b64decode(part["body"]["data"]).decode("utf-8", errors="replace")

        return {
            "id": msg["id"],
            "thread_id": msg.get("threadId", ""),
            "snippet": msg.get("snippet", ""),
            "from": headers.get("From", ""),
            "to": headers.get("To", ""),
            "subject": headers.get("Subject", "(no subject)"),
            "date": headers.get("Date", ""),
            "body": body,
            "label_ids": msg.get("labelIds", []),
        }

    async def get_message(self, message_id: str) -> dict:
        return await self._run_sync(self._get_message_sync, message_id)

    def _send_message_sync(self, to: str, subject: str, body: str) -> dict:
        service = self._get_service()
        message = MIMEText(body)
        message["to"] = to
        message["subject"] = subject
        raw = base64.urlsafe_b64encode(message.as_bytes()).decode()
        return (
            service.users()
            .messages()
            .send(userId="me", body={"raw": raw})
            .execute()
        )

    async def send_message(self, to: str, subject: str, body: str) -> dict:
        return await self._run_sync(self._send_message_sync, to, subject, body)

    def _list_labels_sync(self) -> list[dict]:
        service = self._get_service()
        results = service.users().labels().list(userId="me").execute()
        return results.get("labels", [])

    async def list_labels(self) -> list[dict]:
        return await self._run_sync(self._list_labels_sync)

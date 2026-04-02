from datetime import datetime, timedelta

from app.services.base import BaseGoogleService


class CalendarService(BaseGoogleService):
    """Google Calendar API wrapper supporting multi-account usage."""

    def _get_service(self):
        return self._build_service("calendar", "v3")

    def _list_events_sync(
        self,
        time_min: str | None = None,
        time_max: str | None = None,
        max_results: int = 50,
        calendar_id: str = "primary",
    ) -> list[dict]:
        service = self._get_service()

        if not time_min:
            time_min = datetime.utcnow().isoformat() + "Z"
        if not time_max:
            time_max = (datetime.utcnow() + timedelta(days=30)).isoformat() + "Z"

        results = (
            service.events()
            .list(
                calendarId=calendar_id,
                timeMin=time_min,
                timeMax=time_max,
                maxResults=max_results,
                singleEvents=True,
                orderBy="startTime",
            )
            .execute()
        )

        events = []
        for event in results.get("items", []):
            start = event.get("start", {})
            end = event.get("end", {})
            events.append({
                "id": event["id"],
                "summary": event.get("summary", "(no title)"),
                "description": event.get("description", ""),
                "location": event.get("location", ""),
                "start": start.get("dateTime", start.get("date", "")),
                "end": end.get("dateTime", end.get("date", "")),
                "html_link": event.get("htmlLink", ""),
                "status": event.get("status", ""),
                "attendees": [
                    {"email": a.get("email", ""), "status": a.get("responseStatus", "")}
                    for a in event.get("attendees", [])
                ],
            })
        return events

    async def list_events(self, **kwargs) -> list[dict]:
        return await self._run_sync(self._list_events_sync, **kwargs)

    def _create_event_sync(
        self,
        summary: str,
        start_time: str,
        end_time: str,
        description: str = "",
        location: str = "",
        attendees: list[str] | None = None,
        calendar_id: str = "primary",
    ) -> dict:
        service = self._get_service()

        event_body = {
            "summary": summary,
            "description": description,
            "location": location,
            "start": {"dateTime": start_time, "timeZone": "UTC"},
            "end": {"dateTime": end_time, "timeZone": "UTC"},
        }
        if attendees:
            event_body["attendees"] = [{"email": e} for e in attendees]

        return (
            service.events()
            .insert(calendarId=calendar_id, body=event_body)
            .execute()
        )

    async def create_event(self, **kwargs) -> dict:
        return await self._run_sync(self._create_event_sync, **kwargs)

    def _get_event_sync(self, event_id: str, calendar_id: str = "primary") -> dict:
        service = self._get_service()
        return service.events().get(calendarId=calendar_id, eventId=event_id).execute()

    async def get_event(self, event_id: str, **kwargs) -> dict:
        return await self._run_sync(self._get_event_sync, event_id, **kwargs)

    def _delete_event_sync(self, event_id: str, calendar_id: str = "primary"):
        service = self._get_service()
        service.events().delete(calendarId=calendar_id, eventId=event_id).execute()

    async def delete_event(self, event_id: str, **kwargs):
        return await self._run_sync(self._delete_event_sync, event_id, **kwargs)

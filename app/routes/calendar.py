import asyncio

from fastapi import APIRouter, Depends, Form, Request
from fastapi.responses import RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from app.auth.oauth import get_connected_accounts
from app.database import get_db
from app.services.calendar import CalendarService

router = APIRouter(tags=["calendar"])
templates = Jinja2Templates(directory="app/templates")


@router.get("/calendar")
async def calendar_page(request: Request, db: Session = Depends(get_db)):
    """Show merged calendar view from all connected accounts."""
    accounts = get_connected_accounts(db)
    if not accounts:
        return RedirectResponse(url="/accounts")

    # Fetch events from all accounts in parallel
    tasks = []
    for account in accounts:
        service = CalendarService(db, account.id)
        tasks.append(service.list_events())

    results = await asyncio.gather(*tasks, return_exceptions=True)

    # Merge events, tagging each with account info
    all_events = []
    for account, result in zip(accounts, results):
        if isinstance(result, Exception):
            continue
        for event in result:
            event["account_email"] = account.email
            event["account_slot"] = account.slot
            event["account_id"] = account.id
            all_events.append(event)

    # Sort by start time
    all_events.sort(key=lambda e: e.get("start", ""))

    return templates.TemplateResponse(
        "calendar.html",
        {
            "request": request,
            "events": all_events,
            "accounts": accounts,
            "error": request.query_params.get("error"),
            "success": request.query_params.get("success"),
        },
    )


@router.get("/calendar/create")
async def create_event_page(request: Request, db: Session = Depends(get_db)):
    """Show create event form."""
    accounts = get_connected_accounts(db)
    if not accounts:
        return RedirectResponse(url="/accounts")

    return templates.TemplateResponse(
        "create_event.html",
        {"request": request, "accounts": accounts},
    )


@router.post("/calendar/create")
async def create_event(
    request: Request,
    account_id: int = Form(...),
    summary: str = Form(...),
    start_time: str = Form(...),
    end_time: str = Form(...),
    description: str = Form(""),
    location: str = Form(""),
    db: Session = Depends(get_db),
):
    """Create a calendar event on the selected account."""
    accounts = get_connected_accounts(db)
    account = next((a for a in accounts if a.id == account_id), None)
    if not account:
        return RedirectResponse(url="/calendar?error=invalid_account", status_code=303)

    service = CalendarService(db, account.id)
    try:
        await service.create_event(
            summary=summary,
            start_time=start_time,
            end_time=end_time,
            description=description,
            location=location,
        )
        return RedirectResponse(url="/calendar?success=created", status_code=303)
    except Exception as e:
        return RedirectResponse(url=f"/calendar?error={str(e)[:100]}", status_code=303)

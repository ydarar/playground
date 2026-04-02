import asyncio

from fastapi import APIRouter, Depends, Request
from fastapi.responses import RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from app.auth.oauth import get_connected_accounts
from app.database import get_db
from app.services.gmail import GmailService

router = APIRouter(tags=["inbox"])
templates = Jinja2Templates(directory="app/templates")


@router.get("/")
async def home(request: Request):
    return RedirectResponse(url="/inbox")


@router.get("/inbox")
async def unified_inbox(
    request: Request,
    q: str = "",
    db: Session = Depends(get_db),
):
    """Show unified inbox from all connected accounts."""
    accounts = get_connected_accounts(db)
    if not accounts:
        return RedirectResponse(url="/accounts")

    # Fetch messages from all accounts in parallel
    tasks = []
    for account in accounts:
        service = GmailService(db, account.id)
        tasks.append(service.list_messages(query=q, max_results=15))

    results = await asyncio.gather(*tasks, return_exceptions=True)

    # Merge messages, tagging each with account info
    all_messages = []
    for account, result in zip(accounts, results):
        if isinstance(result, Exception):
            continue
        for msg in result:
            msg["account_email"] = account.email
            msg["account_slot"] = account.slot
            msg["account_id"] = account.id
            all_messages.append(msg)

    # Sort by date (newest first) - rough sort by message ID as fallback
    all_messages.sort(key=lambda m: m.get("date", ""), reverse=True)

    return templates.TemplateResponse(
        "inbox.html",
        {
            "request": request,
            "messages": all_messages,
            "accounts": accounts,
            "query": q,
            "active_filter": "all",
        },
    )


@router.get("/inbox/{slot}")
async def slot_inbox(
    slot: int,
    request: Request,
    q: str = "",
    db: Session = Depends(get_db),
):
    """Show inbox for a specific account slot."""
    accounts = get_connected_accounts(db)
    account = next((a for a in accounts if a.slot == slot), None)
    if not account:
        return RedirectResponse(url="/accounts")

    service = GmailService(db, account.id)
    try:
        messages = await service.list_messages(query=q, max_results=20)
    except Exception:
        messages = []

    for msg in messages:
        msg["account_email"] = account.email
        msg["account_slot"] = account.slot
        msg["account_id"] = account.id

    return templates.TemplateResponse(
        "inbox.html",
        {
            "request": request,
            "messages": messages,
            "accounts": accounts,
            "query": q,
            "active_filter": str(slot),
        },
    )


@router.get("/message/{account_id}/{message_id}")
async def view_message(
    account_id: int,
    message_id: str,
    request: Request,
    db: Session = Depends(get_db),
):
    """View a single email message."""
    accounts = get_connected_accounts(db)
    account = next((a for a in accounts if a.id == account_id), None)
    if not account:
        return RedirectResponse(url="/inbox")

    service = GmailService(db, account.id)
    try:
        message = await service.get_message(message_id)
        message["account_email"] = account.email
    except Exception:
        return RedirectResponse(url="/inbox")

    return templates.TemplateResponse(
        "message.html",
        {
            "request": request,
            "message": message,
            "accounts": accounts,
        },
    )

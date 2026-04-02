from fastapi import APIRouter, Depends, Form, Request
from fastapi.responses import RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from app.auth.oauth import get_connected_accounts
from app.database import get_db
from app.services.gmail import GmailService

router = APIRouter(tags=["compose"])
templates = Jinja2Templates(directory="app/templates")


@router.get("/compose")
async def compose_page(request: Request, db: Session = Depends(get_db)):
    """Show compose email form."""
    accounts = get_connected_accounts(db)
    if not accounts:
        return RedirectResponse(url="/accounts")

    return templates.TemplateResponse(
        "compose.html",
        {
            "request": request,
            "accounts": accounts,
            "error": request.query_params.get("error"),
            "success": request.query_params.get("success"),
        },
    )


@router.post("/compose")
async def send_email(
    request: Request,
    account_id: int = Form(...),
    to: str = Form(...),
    subject: str = Form(...),
    body: str = Form(...),
    db: Session = Depends(get_db),
):
    """Send an email from the selected account."""
    accounts = get_connected_accounts(db)
    account = next((a for a in accounts if a.id == account_id), None)
    if not account:
        return RedirectResponse(url="/compose?error=invalid_account", status_code=303)

    service = GmailService(db, account.id)
    try:
        await service.send_message(to=to, subject=subject, body=body)
        return RedirectResponse(url="/compose?success=sent", status_code=303)
    except Exception as e:
        return RedirectResponse(url=f"/compose?error={str(e)[:100]}", status_code=303)

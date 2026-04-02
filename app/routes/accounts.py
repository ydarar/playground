from fastapi import APIRouter, Depends, Request
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from app.auth.oauth import get_connected_accounts
from app.database import get_db

router = APIRouter(tags=["accounts"])
templates = Jinja2Templates(directory="app/templates")


@router.get("/accounts")
async def accounts_page(request: Request, db: Session = Depends(get_db)):
    """Show connected accounts and allow connecting/disconnecting."""
    accounts = get_connected_accounts(db)
    accounts_by_slot = {a.slot: a for a in accounts}
    return templates.TemplateResponse(
        "accounts.html",
        {
            "request": request,
            "accounts_by_slot": accounts_by_slot,
            "error": request.query_params.get("error"),
            "success": request.query_params.get("success"),
        },
    )

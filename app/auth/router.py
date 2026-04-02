from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import RedirectResponse
from sqlalchemy.orm import Session

from app.auth.oauth import (
    disconnect_account,
    exchange_code_for_credentials,
    get_authorization_url,
    get_user_info,
    parse_state,
    save_account,
)
from app.database import get_db

router = APIRouter(prefix="/auth", tags=["auth"])


@router.get("/login/{slot}")
async def login(slot: int, request: Request):
    """Initiate OAuth2 flow for a specific account slot (0 or 1)."""
    if slot not in (0, 1):
        return RedirectResponse(url="/accounts?error=invalid_slot")

    auth_url, state = get_authorization_url(slot)
    request.session["oauth_state"] = state
    return RedirectResponse(url=auth_url)


@router.get("/callback")
async def callback(
    request: Request,
    code: str = Query(...),
    state: str = Query(...),
    db: Session = Depends(get_db),
):
    """Handle OAuth2 callback from Google."""
    # Validate state
    saved_state = request.session.get("oauth_state")
    if not saved_state or saved_state != state:
        return RedirectResponse(url="/accounts?error=invalid_state")

    parsed = parse_state(state)
    slot = parsed["slot"]

    # Exchange code for credentials
    credentials = exchange_code_for_credentials(code)

    # Get user info
    user_info = get_user_info(credentials)

    # Check if this email is already connected in the other slot
    from app.models import Account

    other_slot = 1 - slot
    existing = (
        db.query(Account)
        .filter(Account.slot == other_slot, Account.email == user_info.get("email"))
        .first()
    )
    if existing:
        return RedirectResponse(url="/accounts?error=duplicate_account")

    # Save account
    save_account(db, slot, credentials, user_info)

    # Clean up session
    request.session.pop("oauth_state", None)
    return RedirectResponse(url="/accounts?success=connected")


@router.get("/logout/{slot}")
async def logout(slot: int, db: Session = Depends(get_db)):
    """Disconnect an account from a slot."""
    if slot not in (0, 1):
        return RedirectResponse(url="/accounts?error=invalid_slot")

    disconnect_account(db, slot)
    return RedirectResponse(url="/accounts?success=disconnected")

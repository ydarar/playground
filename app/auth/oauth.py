import json
import secrets
from datetime import datetime, timedelta

from google.auth.transport.requests import Request as GoogleAuthRequest
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import Flow
from sqlalchemy.orm import Session

from app.auth.encryption import decrypt_token, encrypt_token
from app.config import get_settings
from app.models import Account

MAX_SLOTS = 2


def build_oauth_flow() -> Flow:
    """Build a Google OAuth2 flow using client credentials from settings."""
    settings = get_settings()
    client_config = {
        "web": {
            "client_id": settings.google_client_id,
            "client_secret": settings.google_client_secret,
            "auth_uri": "https://accounts.google.com/o/oauth2/auth",
            "token_uri": "https://oauth2.googleapis.com/token",
            "redirect_uris": [f"{settings.app_base_url}/auth/callback"],
        }
    }
    flow = Flow.from_client_config(
        client_config,
        scopes=settings.google_scopes,
        redirect_uri=f"{settings.app_base_url}/auth/callback",
    )
    return flow


def generate_state(slot: int) -> str:
    """Generate an OAuth state token that encodes the target slot."""
    nonce = secrets.token_urlsafe(32)
    return json.dumps({"slot": slot, "nonce": nonce})


def parse_state(state: str) -> dict:
    """Parse the OAuth state token to extract slot and nonce."""
    return json.loads(state)


def get_authorization_url(slot: int) -> tuple[str, str]:
    """Get the Google OAuth2 authorization URL for a given slot."""
    flow = build_oauth_flow()
    state = generate_state(slot)
    auth_url, _ = flow.authorization_url(
        access_type="offline",
        include_granted_scopes="true",
        prompt="consent",
        state=state,
    )
    return auth_url, state


def exchange_code_for_credentials(code: str) -> Credentials:
    """Exchange an authorization code for Google credentials."""
    flow = build_oauth_flow()
    flow.fetch_token(code=code)
    return flow.credentials


def get_user_info(credentials: Credentials) -> dict:
    """Fetch the authenticated user's profile info."""
    import googleapiclient.discovery

    service = googleapiclient.discovery.build("oauth2", "v2", credentials=credentials)
    return service.userinfo().get().execute()


def save_account(db: Session, slot: int, credentials: Credentials, user_info: dict) -> Account:
    """Save or update an account's credentials in the database."""
    # Remove any existing account in this slot
    db.query(Account).filter(Account.slot == slot).delete()
    db.flush()

    account = Account(
        slot=slot,
        email=user_info.get("email", ""),
        display_name=user_info.get("name", ""),
        picture_url=user_info.get("picture", ""),
        access_token=encrypt_token(credentials.token),
        refresh_token=encrypt_token(credentials.refresh_token or ""),
        token_expiry=credentials.expiry,
        scopes=" ".join(credentials.scopes or []),
    )
    db.add(account)
    db.commit()
    db.refresh(account)
    return account


def load_credentials(db: Session, account_id: int) -> Credentials:
    """Load and refresh credentials for an account."""
    account = db.query(Account).filter(Account.id == account_id).first()
    if not account:
        raise ValueError(f"Account {account_id} not found")

    settings = get_settings()
    creds = Credentials(
        token=decrypt_token(account.access_token),
        refresh_token=decrypt_token(account.refresh_token),
        token_uri="https://oauth2.googleapis.com/token",
        client_id=settings.google_client_id,
        client_secret=settings.google_client_secret,
        scopes=account.scopes.split() if account.scopes else None,
    )

    # Check if token needs refresh
    if account.token_expiry and datetime.utcnow() >= account.token_expiry - timedelta(minutes=5):
        creds.refresh(GoogleAuthRequest())
        # Save refreshed token
        account.access_token = encrypt_token(creds.token)
        account.token_expiry = creds.expiry
        db.commit()

    return creds


def get_connected_accounts(db: Session) -> list[Account]:
    """Get all connected accounts ordered by slot."""
    return db.query(Account).order_by(Account.slot).all()


def disconnect_account(db: Session, slot: int) -> bool:
    """Remove an account from a slot."""
    deleted = db.query(Account).filter(Account.slot == slot).delete()
    db.commit()
    return deleted > 0

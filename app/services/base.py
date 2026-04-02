import asyncio

import googleapiclient.discovery
from google.oauth2.credentials import Credentials
from sqlalchemy.orm import Session

from app.auth.oauth import load_credentials


class BaseGoogleService:
    """Base class for Google API service wrappers."""

    def __init__(self, db: Session, account_id: int):
        self.db = db
        self.account_id = account_id

    def _get_credentials(self) -> Credentials:
        return load_credentials(self.db, self.account_id)

    def _build_service(self, api_name: str, api_version: str):
        creds = self._get_credentials()
        return googleapiclient.discovery.build(
            api_name, api_version, credentials=creds, cache_discovery=False
        )

    async def _run_sync(self, func, *args, **kwargs):
        """Run a synchronous Google API call in a thread."""
        return await asyncio.to_thread(func, *args, **kwargs)

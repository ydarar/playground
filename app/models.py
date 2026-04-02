from datetime import datetime

from sqlalchemy import DateTime, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class Account(Base):
    __tablename__ = "accounts"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    slot: Mapped[int] = mapped_column(Integer, nullable=False)  # 0 or 1
    email: Mapped[str] = mapped_column(String(255), nullable=False)
    display_name: Mapped[str] = mapped_column(String(255), default="")
    picture_url: Mapped[str] = mapped_column(String(512), default="")
    access_token: Mapped[str] = mapped_column(Text, nullable=False)  # Fernet-encrypted
    refresh_token: Mapped[str] = mapped_column(Text, nullable=False)  # Fernet-encrypted
    token_expiry: Mapped[datetime] = mapped_column(DateTime, nullable=True)
    scopes: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=datetime.utcnow, onupdate=datetime.utcnow
    )

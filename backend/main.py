import hmac
import logging
import os
from typing import Literal

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

import ai

load_dotenv()
log = logging.getLogger("ronghor")

app = FastAPI(
    title="Ronghor AI API",
    description="Backend for the Ronghor AI Android app",
    version="0.2.0",
)

origins = os.getenv("APP_ALLOWED_ORIGINS", "*").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[origin.strip() for origin in origins],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


class HistoryItem(BaseModel):
    role: Literal["user", "assistant"]
    content: str = Field(max_length=30000)


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=12000)
    web_search: bool = False
    history: list[HistoryItem] = Field(default_factory=list, max_length=12)


class ChatResponse(BaseModel):
    answer: str


def require_access(authorization: str | None = Header(default=None)) -> None:
    """Check the app's access key so strangers cannot spend your AI credits."""
    expected = os.getenv("APP_ACCESS_KEY", "")
    if not expected:
        if os.getenv("ALLOW_NO_AUTH", "").lower() in ("1", "true", "yes"):
            return
        raise HTTPException(
            status_code=503,
            detail="The server has no APP_ACCESS_KEY set. Add one in the server's environment settings.",
        )
    supplied = ""
    if authorization and authorization.lower().startswith("bearer "):
        supplied = authorization[7:].strip()
    if not hmac.compare_digest(supplied.encode(), expected.encode()):
        raise HTTPException(status_code=401, detail="Invalid access key.")


@app.get("/")
def root():
    return {"app": "Ronghor AI API", "status": "ok"}


@app.get("/health")
def health():
    return {"status": "healthy"}


@app.get("/ping", dependencies=[Depends(require_access)])
def ping():
    """Used by the app's 'Test connection' button."""
    return ai.describe_config()


@app.post("/chat", response_model=ChatResponse, dependencies=[Depends(require_access)])
def chat(body: ChatRequest):
    try:
        answer = ai.generate_answer(
            [item.model_dump() for item in body.history],
            body.message,
            body.web_search,
        )
        return ChatResponse(answer=answer)
    except Exception as exc:  # noqa: BLE001 - mapped to a safe message below
        status, detail = ai.describe_error(exc)
        if status >= 500:
            log.exception("chat request failed")
        raise HTTPException(status_code=status, detail=detail) from exc

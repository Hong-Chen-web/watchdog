"""公共依赖:连接获取、日期校验、错误信封。"""
import sqlite3
from datetime import date
from pathlib import Path
from typing import Optional

from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse

import db as dbm


def get_conn() -> sqlite3.Connection:
    return dbm.connect()


def validate_date(s: Optional[str]) -> Optional[str]:
    if s in (None, ""):
        return None
    try:
        date.fromisoformat(s)
        return s
    except ValueError:
        raise HTTPException(400, f"bad date {s!r}, want YYYY-MM-DD")


async def http_error(request: Request, exc: HTTPException):
    """统一错误信封:{error:{code,message}}(设计说明书第 10 节)"""
    code = getattr(exc, "code", None) or {
        400: "BAD_REQUEST", 404: "NOT_FOUND", 409: "CONFLICT", 502: "UPSTREAM_FAILED",
    }.get(exc.status_code, "ERROR")
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": {"code": code, "message": str(exc.detail)}},
    )

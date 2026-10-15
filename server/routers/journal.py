"""日志模块接口:/api/journal(每日总结 + 自由笔记 + 当日完成事件时间线)。"""
from datetime import date
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from .common import get_conn, validate_date

router = APIRouter(prefix="/api/journal", tags=["journal"])


def _today_events(conn, day: str) -> list:
    """当日完成/总结过的 todo,按完成时间倒序。"""
    rows = conn.execute(
        "SELECT id, title, summary, priority, completed_at, due_date"
        " FROM todos WHERE done=1"
        " AND (substr(completed_at,1,10)=? OR (summary IS NOT NULL AND due_date=?))"
        " ORDER BY completed_at DESC", (day, day)).fetchall()
    return [{"todo_id": r["id"], "title": r["title"], "summary": r["summary"],
             "priority": r["priority"], "completed_at": r["completed_at"]}
            for r in rows]


@router.get("")
def journal_list(day: str = None, limit: int = 60):
    day = day or date.today().isoformat()
    validate_date(day)
    conn = get_conn()
    try:
        entries = [dict(r) for r in conn.execute(
            "SELECT id, date, kind, content, created_at FROM journal"
            " ORDER BY date DESC, id DESC LIMIT ?", (min(limit, 200),)).fetchall()]
        return {"date": day,
                "events": _today_events(conn, day),
                "entries": entries,
                "today_summary": next((e["content"] for e in entries
                                       if e["kind"] == "daily" and e["date"] == day), None)}
    finally:
        conn.close()


class JournalIn(BaseModel):
    date: Optional[str] = None
    kind: str = Field(pattern="^(daily|note)$")
    content: str = Field(min_length=1, max_length=4000)


@router.post("", status_code=201)
def journal_write(body: JournalIn):
    day = validate_date(body.date) or date.today().isoformat()
    conn = get_conn()
    try:
        if body.kind == "daily":  # 每日总结当天唯一,重写覆盖
            cur = conn.execute("SELECT id FROM journal WHERE kind='daily' AND date=?",
                               (day,)).fetchone()
            if cur:
                conn.execute("UPDATE journal SET content=? WHERE id=?",
                             (body.content, cur["id"]))
                conn.commit()
                return {"id": cur["id"], "updated": True}
        cur = conn.execute(
            "INSERT INTO journal(date,kind,content) VALUES(?,?,?)",
            (day, body.kind, body.content.strip()))
        conn.commit()
        return {"id": cur.lastrowid, "updated": False}
    finally:
        conn.close()


@router.delete("/{jid}", status_code=204)
def journal_delete(jid: int):
    conn = get_conn()
    try:
        cur = conn.execute("DELETE FROM journal WHERE id=?", (jid,))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, f"journal {jid} not found")
    finally:
        conn.close()

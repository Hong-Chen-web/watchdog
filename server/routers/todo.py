"""待办模块接口:/api/todos(todos 表)。"""
from datetime import date
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from .common import get_conn, validate_date

router = APIRouter(prefix="/api/todos", tags=["todo"])


class TodoIn(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    due_date: Optional[str] = None
    priority: int = Field(default=3, ge=1, le=3)


class TodoPatch(BaseModel):
    title: Optional[str] = Field(default=None, min_length=1, max_length=200)
    due_date: Optional[str] = None
    priority: Optional[int] = Field(default=None, ge=1, le=3)
    done: Optional[bool] = None
    summary: Optional[str] = Field(default=None, max_length=500)  # 完成总结


def _todo_out(r, today: str) -> dict:
    d = dict(r)
    d["done"] = bool(d["done"])
    d["overdue"] = bool(d["due_date"] and not d["done"] and d["due_date"] < today)
    d["today"] = d["due_date"] == today
    return d


@router.get("")
def list_todos(date_filter: Optional[str] = None, status: str = "all"):
    q = "SELECT * FROM todos"
    if status == "open":
        q += " WHERE done=0"
    elif status == "done":
        q += " WHERE done=1"
    q += " ORDER BY done, due_date IS NULL, due_date, id DESC"
    conn = get_conn()
    try:
        rows = conn.execute(q).fetchall()
    finally:
        conn.close()
    today = date.today().isoformat()
    out = [_todo_out(r, today) for r in rows]
    if date_filter:
        out = [t for t in out if t["due_date"] == date_filter]
    return out


@router.post("", status_code=201)
def create_todo(body: TodoIn):
    conn = get_conn()
    try:
        cur = conn.execute(
            "INSERT INTO todos(title, due_date, priority) VALUES(?,?,?)",
            (body.title.strip(), validate_date(body.due_date), body.priority))
        conn.commit()
        row = conn.execute("SELECT * FROM todos WHERE id=?",
                           (cur.lastrowid,)).fetchone()
    finally:
        conn.close()
    return _todo_out(row, date.today().isoformat())


@router.patch("/{tid}")
def patch_todo(tid: int, body: TodoPatch):
    sets, args = [], []
    if body.title is not None:
        sets.append("title=?"); args.append(body.title.strip())
    if body.due_date is not None:
        sets.append("due_date=?"); args.append(validate_date(body.due_date))
    if body.priority is not None:
        sets.append("priority=?"); args.append(body.priority)
    if body.summary is not None:
        sets.append("summary=?"); args.append(body.summary.strip() or None)
    if body.done is not None:
        sets.append("done=?"); args.append(int(body.done))
        sets.append("completed_at=" + (
            "datetime('now','localtime')" if body.done else "NULL"))
    if not sets:
        raise HTTPException(400, "nothing to update")
    args.append(tid)
    conn = get_conn()
    try:
        cur = conn.execute(f"UPDATE todos SET {', '.join(sets)} WHERE id=?", args)
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, f"todo {tid} not found")
        row = conn.execute("SELECT * FROM todos WHERE id=?", (tid,)).fetchone()
    finally:
        conn.close()
    return _todo_out(row, date.today().isoformat())


@router.delete("/{tid}", status_code=204)
def delete_todo(tid: int):
    conn = get_conn()
    try:
        cur = conn.execute("DELETE FROM todos WHERE id=?", (tid,))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, f"todo {tid} not found")
    finally:
        conn.close()


@router.get("/stats")
def todo_stats():
    today = date.today().isoformat()
    conn = get_conn()
    try:
        one = lambda sql, a=(): conn.execute(sql, a).fetchone()["c"]  # noqa: E731
        total = one("SELECT COUNT(*) c FROM todos")
        done = one("SELECT COUNT(*) c FROM todos WHERE done=1")
        overdue = one("SELECT COUNT(*) c FROM todos WHERE done=0"
                      " AND due_date IS NOT NULL AND due_date<?", (today,))
        today_left = one("SELECT COUNT(*) c FROM todos WHERE done=0 AND due_date=?",
                         (today,))
    finally:
        conn.close()
    return {"total": total, "done": done, "open": total - done,
            "overdue": overdue, "today_left": today_left}

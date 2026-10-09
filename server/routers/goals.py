"""目标模块接口:/api/goals。
周期用枚举维护:month=月度目标 year=年度目标 long=长期目标(如 Numbers 的 14 年长期表)。
预算侧的周期枚举(monthly/yearly)体现在 ledger_budgets 的 monthly/annual 两列。"""
from datetime import date
from enum import Enum
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from .common import get_conn, validate_date

router = APIRouter(prefix="/api/goals", tags=["goals"])


class GoalScope(str, Enum):
    MONTH = "month"   # 月度目标
    YEAR = "year"     # 年度目标
    LONG = "long"     # 长期目标


SCOPE_LABELS = {GoalScope.MONTH: "月度目标", GoalScope.YEAR: "年度目标",
                GoalScope.LONG: "长期目标"}


@router.get("")
def list_goals(scope: Optional[GoalScope] = None):
    conn = get_conn()
    try:
        q = ("SELECT id, scope, title, start_date, review_date, detail, result,"
             " source, sort FROM goals")
        args = []
        if scope:
            q += " WHERE scope=?"
            args.append(scope.value)
        q += " ORDER BY scope, sort, id"
        rows = [dict(r) for r in conn.execute(q, args).fetchall()]
        groups = [{"scope": s.value, "label": SCOPE_LABELS[s],
                   "items": [r for r in rows if r["scope"] == s.value]}
                  for s in GoalScope]
        return {"groups": [g for g in groups if g["items"] or g["scope"] != "month"],
                "today": date.today().isoformat()}
    finally:
        conn.close()


class GoalIn(BaseModel):
    scope: GoalScope
    title: str = Field(min_length=1, max_length=120)
    review_date: Optional[str] = None
    detail: Optional[str] = Field(default=None, max_length=4000)


@router.post("", status_code=201)
def create_goal(body: GoalIn):
    conn = get_conn()
    try:
        cur = conn.execute(
            "INSERT INTO goals(scope,title,review_date,detail,source)"
            " VALUES(?,?,?,?, 'manual')",
            (body.scope.value, body.title.strip(), validate_date(body.review_date),
             (body.detail or "").strip() or None))
        conn.commit()
        return {"id": cur.lastrowid, "ok": True}
    finally:
        conn.close()


class GoalPatch(BaseModel):
    title: Optional[str] = Field(default=None, min_length=1, max_length=120)
    detail: Optional[str] = Field(default=None, max_length=4000)
    result: Optional[str] = Field(default=None, max_length=1000)
    review_date: Optional[str] = None


@router.patch("/{gid}")
def patch_goal(gid: int, body: GoalPatch):
    sets, args = [], []
    if body.title is not None:
        sets.append("title=?"); args.append(body.title.strip())
    if body.detail is not None:
        sets.append("detail=?"); args.append((body.detail or "").strip() or None)
    if body.result is not None:
        sets.append("result=?"); args.append(body.result.strip() or None)
    if body.review_date is not None:
        sets.append("review_date=?"); args.append(validate_date(body.review_date))
    if not sets:
        raise HTTPException(400, "nothing to update")
    args.append(gid)
    conn = get_conn()
    try:
        cur = conn.execute(f"UPDATE goals SET {', '.join(sets)} WHERE id=?", args)
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, f"goal {gid} not found")
        return {"ok": True}
    finally:
        conn.close()


@router.delete("/{gid}", status_code=204)
def delete_goal(gid: int):
    conn = get_conn()
    try:
        cur = conn.execute("DELETE FROM goals WHERE id=? AND source='manual'", (gid,))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, "仅支持删除手动创建的目标")
    finally:
        conn.close()

"""Rules shared by all HTTP features. No device timezone or system-date mutation."""

from datetime import date, datetime, time, timedelta, timezone
import base64
import json
import re
import unicodedata
from zoneinfo import ZoneInfo

DAY_ZONE = ZoneInfo("Asia/Shanghai")
STEPS_PER_FLOOR = 100
MAX_STEPS = 1_000_000
MAX_NICKNAME_LENGTH = 24
MAX_BODY_BYTES = 4096
DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100
CIRCLE_BAND_STEPS = 1000


class APIError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


def utc_now():
    return datetime.now(timezone.utc)


def day_context(now):
    if now.tzinfo is None:
        raise ValueError("Clock must return a timezone-aware datetime")
    local = now.astimezone(DAY_ZONE)
    start = datetime.combine(local.date(), time.min, tzinfo=DAY_ZONE)
    return {
        "date": local.date().isoformat(),
        "timezone": DAY_ZONE.key,
        "day_start": start.isoformat(),
        "day_end": (start + timedelta(days=1)).isoformat(),
        "steps_per_floor": STEPS_PER_FLOOR,
        "max_steps": MAX_STEPS,
        "circle_band_steps": CIRCLE_BAND_STEPS,
    }


def progress(steps):
    if type(steps) is not int or not 0 <= steps <= MAX_STEPS:
        raise APIError(422, "invalid_steps", f"步数必须是 0 至 {MAX_STEPS} 的整数")
    return {
        "steps": steps,
        "floor": steps // STEPS_PER_FLOOR,
        "remaining_steps": STEPS_PER_FLOOR - steps % STEPS_PER_FLOOR,
    }


def nickname(value):
    if not isinstance(value, str):
        raise APIError(422, "invalid_nickname", "昵称必须是文字")
    value = value.strip()
    # Unicode scalar count; spaces inside a name may only be ordinary U+0020.
    if not 1 <= len(value) <= MAX_NICKNAME_LENGTH or any(
        not char.isprintable() or unicodedata.category(char).startswith("C")
        for char in value
    ):
        raise APIError(422, "invalid_nickname", "昵称须为 1 至 24 个可见字符，可含普通空格")
    return value


def exact_fields(body, required):
    if set(body) != set(required):
        raise APIError(422, "invalid_fields", "请求字段不符合接口定义")


def revision(value):
    if type(value) is not int or not 0 <= value <= 2**63 - 1:
        raise APIError(422, "invalid_revision", "共享版本必须是非负整数")
    return value


def current_date(value, context):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
        raise APIError(422, "invalid_date", "日期须为 YYYY-MM-DD")
    try:
        date.fromisoformat(value)
    except ValueError:
        raise APIError(422, "invalid_date", "日期无效") from None
    if value != context["date"]:
        raise APIError(409, "day_changed", "仅可同步上海当日步数，请重新读取当日健康数据")
    return value


def page_size(value):
    if value is None:
        return DEFAULT_PAGE_SIZE
    if not re.fullmatch(r"[0-9]{1,3}", value) or not 1 <= int(value) <= MAX_PAGE_SIZE:
        raise APIError(422, "invalid_limit", f"每页数量须为 1 至 {MAX_PAGE_SIZE}")
    return int(value)


def page_cursor(snapshot, offset, limit):
    # A read-only continuation, containing no credentials or health summaries.
    raw = json.dumps([snapshot, offset, limit], separators=(",", ":")).encode("ascii")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def read_cursor(value, snapshot, limit):
    try:
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,256}", value):
            raise ValueError()
        raw = base64.b64decode(value + "=" * (-len(value) % 4), altchars=b"-_", validate=True)
        decoded = json.loads(raw)
        if not isinstance(decoded, list) or len(decoded) != 3:
            raise ValueError()
        saved, offset, saved_limit = decoded
        if (not isinstance(saved, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]+", saved)
                or type(offset) is not int or not 0 <= offset <= 2**63 - 1
                or type(saved_limit) is not int or saved_limit != limit
                or value != page_cursor(saved, offset, saved_limit)):
            raise ValueError()
    except (ValueError, TypeError, UnicodeError):
        raise APIError(422, "invalid_cursor", "分页游标无效或每页数量已改变，请刷新") from None
    if saved != snapshot:
        raise APIError(409, "leaderboard_changed", "日期或排行榜已变化，请从首页刷新")
    return offset


def circle_for_steps(date, steps):
    progress(steps)
    lower = (steps // CIRCLE_BAND_STEPS) * CIRCLE_BAND_STEPS
    upper = lower + CIRCLE_BAND_STEPS - 1
    return {"id": f"{date}:{lower}-{upper}", "date": date,
            "min_steps": lower, "max_steps": upper, "band_steps": CIRCLE_BAND_STEPS}


def circle_cursor(snapshot, channel, offset, limit):
    raw = json.dumps([snapshot, channel, offset, limit], separators=(",", ":")).encode("ascii")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def read_circle_cursor(value, snapshot, channel, limit):
    try:
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,384}", value):
            raise ValueError()
        decoded = json.loads(base64.b64decode(value + "=" * (-len(value) % 4),
                                             altchars=b"-_", validate=True))
        if not isinstance(decoded, list) or len(decoded) != 4:
            raise ValueError()
        saved, saved_channel, offset, saved_limit = decoded
        if (not isinstance(saved, str) or not isinstance(saved_channel, str)
                or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]+", saved)
                or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}:[0-9]+-[0-9]+", saved_channel)
                or type(offset) is not int or not 0 <= offset <= 2**63 - 1
                or type(saved_limit) is not int or saved_limit != limit
                or value != circle_cursor(saved, saved_channel, offset, saved_limit)):
            raise ValueError()
    except (ValueError, TypeError, UnicodeError):
        raise APIError(422, "invalid_cursor", "圈子分页游标无效或每页数量已改变，请刷新") from None
    if saved != snapshot or saved_channel != channel:
        raise APIError(409, "circle_changed", "日期、圈子或成员已变化，请刷新今日圈子")
    return offset

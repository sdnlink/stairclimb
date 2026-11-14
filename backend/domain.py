"""Rules shared by all HTTP features. No device timezone or system-date mutation."""

from datetime import datetime, time, timedelta, timezone
import unicodedata
from zoneinfo import ZoneInfo

DAY_ZONE = ZoneInfo("Asia/Shanghai")
STEPS_PER_FLOOR = 100
MAX_STEPS = 1_000_000
MAX_NICKNAME_LENGTH = 24
MAX_BODY_BYTES = 4096


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

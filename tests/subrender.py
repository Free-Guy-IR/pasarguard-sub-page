from datetime import datetime, timedelta, timezone
from pathlib import Path

import jinja2

REPO_ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = REPO_ROOT / "index.html"

SUBSCRIPTION_URL = "https://example.invalid/sub/EXAMPLETOKEN"


class User:
    def __init__(self, status):
        self.username = "matrix_user"
        self.status = status
        self.used_traffic = 1024 ** 3
        self.data_limit = 10 * 1024 ** 3
        self.expire = datetime.now(timezone.utc) + timedelta(days=1)
        self.note = ""
        self.online_at = None
        self.sub_updated_at = None
        self.subscription_url = SUBSCRIPTION_URL


def build_environment(template_dir):
    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(str(template_dir)),
        undefined=jinja2.ChainableUndefined,
        autoescape=False,
    )
    env.filters.setdefault("bytesformat", lambda v: "%.2f GB" % (float(v or 0) / 1024 ** 3))
    env.filters.setdefault("datetime", lambda v, *a, **k: "2026-09-14 12:00:00")
    env.globals["now"] = lambda: datetime.now(timezone.utc)
    return env


def render(links, ovpn, l2tp, status, template=TEMPLATE):
    template = Path(template).resolve()
    env = build_environment(template.parent)
    return env.get_template(template.name).render(
        user=User(status),
        links=links,
        openvpn_configs=ovpn,
        l2tp_details=l2tp,
        subscription_url=SUBSCRIPTION_URL,
        announce_url="",
        support_url="",
        icon_url="",
        configs_hidden_by_hwid=False,
    )

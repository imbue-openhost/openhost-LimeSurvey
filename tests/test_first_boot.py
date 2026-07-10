"""First-boot smoke tests.

The app is public (public_paths = ["/"]): anonymous respondents reach surveys,
while the owner is auto-logged into the admin panel via the router-injected
X-OpenHost-Is-Owner header (Authwebserver plugin).

- ``stack.url`` goes through the mock router, which injects the owner header
  on every request — this is the owner's view.
- ``stack.app_url`` hits the container directly with no header — this is the
  anonymous visitor's view.

LimeSurvey builds absolute redirect URLs from HOST_INFO
(https://{app}.{zone}), which is correct in production but not reachable from
the test host, so the requests-based helpers rewrite that origin back to the
base URL under test.
"""

import re
import time
from urllib.parse import urljoin

import requests
from openhost_test_harness import OpenhostStack
from playwright.sync_api import Browser

LOGIN_PATH = "/index.php/admin/authentication/sa/login"


def _external_origin(stack: OpenhostStack) -> str:
    return f"https://{stack.manifest.app.name}.{stack.zone_domain}"


def _get_following_redirects(
    sess: requests.Session, stack: OpenhostStack, base: str, path: str
) -> requests.Response:
    ext = _external_origin(stack)
    url = base + path
    for _ in range(8):
        resp = sess.get(url, allow_redirects=False, timeout=30)
        if resp.status_code not in (301, 302, 303):
            return resp
        loc = resp.headers["Location"]
        url = base + loc[len(ext):] if loc.startswith(ext) else urljoin(url, loc)
    raise AssertionError(f"too many redirects, last at {url}")


def _wait_for_sso_provisioning(stack: OpenhostStack) -> None:
    """The start script activates the Authwebserver plugin in the background
    once the installer has created the schema; allow a few seconds for it."""
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        resp = _get_following_redirects(requests.Session(), stack, stack.url, "/index.php/admin")
        if 'name="password"' not in resp.text:
            return
        time.sleep(2)
    raise AssertionError("owner SSO never became active — still seeing the login form")


def test_health(stack: OpenhostStack) -> None:
    """health.php verifies DB connectivity and that the schema is installed."""
    resp = requests.get(stack.app_url + "/health.php", timeout=10)
    assert resp.status_code == 200, resp.text
    assert resp.text.strip() == "ok"


def test_anonymous_can_reach_survey_pages(stack: OpenhostStack) -> None:
    """No owner header (direct container access) — the survey front page must
    still be served, since respondents are anonymous."""
    resp = _get_following_redirects(requests.Session(), stack, stack.app_url, "/")
    assert resp.status_code == 200
    assert "survey" in resp.text.lower()


def test_anonymous_admin_gets_login_form(stack: OpenhostStack) -> None:
    """Without the owner header the admin panel must demand credentials."""
    resp = _get_following_redirects(requests.Session(), stack, stack.app_url, "/index.php/admin")
    assert resp.status_code == 200
    assert 'name="password"' in resp.text, "expected the LimeSurvey login form"


def test_owner_is_autologged_into_admin(stack: OpenhostStack, browser: Browser) -> None:
    """Through the router (owner header injected) the admin panel opens with
    no login form."""
    _wait_for_sso_provisioning(stack)

    sess = requests.Session()
    resp = _get_following_redirects(sess, stack, stack.url, "/index.php/admin")
    assert resp.status_code == 200
    assert 'name="password"' not in resp.text, "owner hit the login form — SSO failed"
    assert "/dashboard/" in resp.url, f"did not land on the dashboard: {resp.url}"

    # Render the dashboard in a real browser with the SSO session's cookies.
    # (The browser can't follow the login redirect itself: LimeSurvey redirects
    # to the absolute production origin, unreachable from the test host.)
    context = browser.new_context()
    context.add_cookies(
        [{"name": c.name, "value": c.value, "url": stack.url} for c in sess.cookies]
    )
    page = context.new_page()
    try:
        page.goto(stack.url + "/index.php/dashboard/view", wait_until="networkidle")
        page.screenshot(path="tests/_admin_dashboard.png", full_page=True)
        assert page.locator("input[name='password']").count() == 0
        assert stack.owner_username in page.content()
    finally:
        context.close()


def test_anonymous_password_login_still_works(stack: OpenhostStack) -> None:
    """The generated credentials remain a fallback (Authwebserver is not the
    default auth method), e.g. for additional admin users."""
    admin_password = (stack.data_dir / "secrets" / "admin_password").read_text().strip()

    sess = requests.Session()
    login = _get_following_redirects(sess, stack, stack.app_url, "/index.php/admin")
    assert login.status_code == 200

    hidden = {}
    for tag in re.findall(r"<input[^>]*type=['\"]hidden['\"][^>]*>", login.text):
        name = re.search(r"name=['\"]([^'\"]+)['\"]", tag)
        value = re.search(r"value=['\"]([^'\"]*)['\"]", tag)
        if name:
            hidden[name.group(1)] = value.group(1) if value else ""
    assert "YII_CSRF_TOKEN" in hidden, f"no CSRF token on login page: {sorted(hidden)}"

    resp = sess.post(
        stack.app_url + LOGIN_PATH,
        data={
            **hidden,
            "user": stack.owner_username,
            "password": admin_password,
            "login_submit": "login",
        },
        allow_redirects=False,
        timeout=30,
    )
    assert resp.status_code in (301, 302, 303), (
        f"login POST did not redirect (status {resp.status_code}) — "
        "credentials likely rejected"
    )

    dashboard = _get_following_redirects(sess, stack, stack.app_url, "/index.php/admin")
    assert dashboard.status_code == 200
    assert "authentication/sa/login" not in dashboard.url, "bounced back to login"
    assert 'name="password"' not in dashboard.text, "login form still showing"

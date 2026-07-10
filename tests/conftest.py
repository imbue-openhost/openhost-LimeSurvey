"""Shared pytest fixtures.

Builds the LimeSurvey container (with its bundled MariaDB) and fronts it with
the mock OpenHost router, which injects ``X-OpenHost-Is-Owner: true`` exactly
like the real router does for the authenticated compute-space owner.
"""

from collections.abc import Iterator

import pytest
from openhost_test_harness import OpenhostStack
from playwright.sync_api import Browser, Page, sync_playwright


@pytest.fixture(scope="session")
def stack() -> Iterator[OpenhostStack]:
    # First boot initializes the MariaDB data directory and runs LimeSurvey's
    # CLI installer (creates ~200 tables), so give it a generous window. The
    # /health.php readiness probe only passes once the schema is installed.
    with OpenhostStack(readiness_timeout=300) as s:
        yield s


@pytest.fixture(scope="session")
def browser() -> Iterator[Browser]:
    with sync_playwright() as p:
        b = p.chromium.launch()
        try:
            yield b
        finally:
            b.close()


@pytest.fixture
def page(browser: Browser) -> Iterator[Page]:
    context = browser.new_context()
    pg = context.new_page()
    try:
        yield pg
    finally:
        context.close()

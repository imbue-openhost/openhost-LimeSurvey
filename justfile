default: test

# Install test dependencies and the playwright chromium browser.
setup:
    uv sync
    uv run playwright install chromium

# Run the test suite (builds the container under podman; podman must be running).
test:
    uv run pytest -x

# Build the container image locally.
build:
    podman build -t openhost-limesurvey .

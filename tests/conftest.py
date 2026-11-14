"""Keep every test inside temporary user state; desktop tests are opt-in."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "libexec"))


def pytest_addoption(parser):
    parser.addoption("--run-macos-ui", action="store_true", default=False,
                     help="run native desktop tests (explicit opt-in only)")


def pytest_collection_modifyitems(config, items):
    if not config.getoption("--run-macos-ui"):
        for item in items:
            if item.get_closest_marker("macos_ui"):
                item.add_marker(pytest.mark.skip(reason="native desktop tests require --run-macos-ui"))


@pytest.fixture(autouse=True)
def isolated_user_state(tmp_path, monkeypatch):
    home = tmp_path / "sandbox-home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    for name, relative in (("XDG_CONFIG_HOME", ".config"), ("XDG_CACHE_HOME", ".cache"),
                           ("XDG_STATE_HOME", ".local/state")):
        monkeypatch.setenv(name, str(home / relative))


@pytest.fixture(autouse=True)
def isolate_native_install(monkeypatch):
    # Source compatibility tests must never route into a personal installed app.
    monkeypatch.setenv("NIGHTR_TEST_NO_NATIVE", "1")

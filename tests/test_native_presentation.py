"""Static launch packaging checks; no app or system service is launched."""
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_login_controller_agent_remains_headless():
    agent = plistlib.loads((ROOT / "packaging/ai.nightr.agent.plist").read_bytes())
    assert agent["ProgramArguments"] == ["NightrApp", "--controller-only"]
    assert agent["KeepAlive"] == {"SuccessfulExit": False}
    assert agent["ThrottleInterval"] == 30

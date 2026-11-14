"""The bundled companion works without dotfiles and never starts during setup."""
import importlib.util
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]


def isolated(tmp_path):
    home = tmp_path / 'home'
    home.mkdir()
    (home / '.zshrc').write_text('print unexpected-startup; exit 99\n')
    (home / '.zshenv').write_text('print unexpected-startup; exit 99\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith('COV_CORE_')}
    env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'),
               XDG_CACHE_HOME=str(home / '.cache'), XDG_STATE_HOME=str(home / '.local/state'),
               ZDOTDIR=str(home), NO_COLOR='1')
    return home, env


@pytest.mark.parametrize("name", ["nightr", "nosleep"])
def test_clean_shell_help_and_defaults(tmp_path, name):
    home, env = isolated(tmp_path)
    for args, expected in [(['--help'], 'nosleep —'), (['config', '--show'], 'nosleep defaults')]:
        result = subprocess.run([str(ROOT / 'bin' / name), *args], env=env,
                                text=True, capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr
        assert expected in result.stdout
        assert 'unexpected-startup' not in result.stdout
    assert not (home / '.config').exists()


def test_standalone_existing_config_is_unchanged(tmp_path):
    home, env = isolated(tmp_path)
    config = home / '.config/nosleep/config.json'
    config.parent.mkdir(parents=True)
    config.write_text('{"grace": 42, "dim": true}\n')
    before = config.read_bytes()
    result = subprocess.run([str(ROOT / 'bin/nosleep'), 'config', '--show'], env=env,
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and '42s' in result.stdout and 'Dim' in result.stdout
    assert config.read_bytes() == before


def test_shell_adapter_preserves_unexported_overrides(tmp_path):
    _, env = isolated(tmp_path)
    result = subprocess.run(['zsh', '-f', '-c', '''
NOSLEEP_NET_MIN=123 NOSLEEP_NET_BPS=9
NOSLEEP_DIM_LEVEL=0.2
typeset -A NOSLEEP_APPS=(Custom 'Custom app')
source "$1/zsh/nosleep.zsh"
print -r -- "$NOSLEEP_NET_MIN|$NOSLEEP_NET_BPS|$NOSLEEP_DIM_LEVEL|$NOSLEEP_APPS[Custom]"
nosleep --help
''', 'test', str(ROOT)], env=env, text=True, capture_output=True, timeout=10)
    assert result.returncode == 0
    assert '123|9|0.2|Custom app' in result.stdout
    assert 'nosleep —' in result.stdout


@pytest.mark.parametrize("name", ["nightr", "nosleep"])
def test_launcher_resolves_own_repo_and_ignores_t_selection(tmp_path, monkeypatch, name):
    module = runpy.run_path(str(ROOT / "bin" / name))
    monkeypatch.setenv("T_SOURCE_ROOT", str(tmp_path / "unrelated-t"))
    monkeypatch.setattr(sys, "argv", [name, "--help"])
    monkeypatch.setattr(runpy, "run_path", lambda *_: pytest.fail("launcher loaded t"))
    calls = []
    monkeypatch.setattr(os, "execvp", lambda *args: calls.append(args))
    module["main"]()
    assert calls[0][1][-2:] == [str(ROOT), "--help"]


def test_non_macos_monitoring_never_launches(tmp_path):
    _, env = isolated(tmp_path)
    bins = tmp_path / 'bin'
    bins.mkdir()
    for name, body in [('uname', 'echo Linux'), ('sudo', 'echo unexpected-power; exit 99')]:
        target = bins / name
        target.write_text('#!/bin/sh\n' + body + '\n')
        target.chmod(0o755)
    env['PATH'] = str(bins) + os.pathsep + env['PATH']
    result = subprocess.run([str(ROOT / 'bin/nosleep')], env=env,
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 1
    assert 'macOS-only' in result.stderr
    assert 'unexpected-power' not in result.stdout
    # Flag parsing and help still work with grouped compatibility options.
    result = subprocess.run([str(ROOT / 'bin/nosleep'), '-dMLh'], env=env,
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and 'SHORTCUTS' in result.stdout




@pytest.mark.parametrize("name", ["nightr", "nosleep"])
def test_copied_checkout_and_link_work_without_t(tmp_path, name):
    _, env = isolated(tmp_path)
    standalone = tmp_path / "standalone"
    for directory in ("bin", "libexec", "zsh"):
        shutil.copytree(ROOT / directory, standalone / directory)
    link = tmp_path / name
    link.symlink_to(standalone / "bin" / name)
    env["T_SOURCE_ROOT"] = str(tmp_path / "missing-t")
    result = subprocess.run([str(link), "config", "--show"], cwd=tmp_path,
                            env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert "nosleep defaults" in result.stdout
    assert not (standalone / "bin/t").exists()


def test_shell_adapter_never_delegates_to_t(tmp_path):
    _, env = isolated(tmp_path)
    result = subprocess.run(["zsh", "-f", "-c", '''
_t_reload_if_moved() { print unexpected-t-reload; return 99; }
source "$1/zsh/nosleep.zsh"
nosleep --help
''', "test", str(ROOT)], env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert "nosleep —" in result.stdout
    assert "unexpected-t-reload" not in result.stdout


@pytest.mark.parametrize("name", ["nightr", "nosleep"])
@pytest.mark.parametrize("mode", ["ok", "foreign-owner", "writable", "symlink", "bad-signature", "absent", "incomplete"])
def test_native_alias_validates_canonical_install(monkeypatch, name, mode):
    import stat
    from types import SimpleNamespace
    module = runpy.run_path(str(ROOT / "bin" / name))
    namespace = module["installed_native"].__globals__
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.delenv("NIGHTR_TEST_NO_NATIVE")
    calls = []
    def fake_lstat(path):
        if mode == "absent" or (mode == "incomplete" and path.name == "nightr-native"):
            raise FileNotFoundError
        return SimpleNamespace(st_uid=1 if mode == "foreign-owner" else 0,
                               st_mode=(stat.S_IFLNK if mode == "symlink" else stat.S_IFREG) | (0o777 if mode == "writable" else 0o755))
    monkeypatch.setattr(Path, "lstat", fake_lstat)
    monkeypatch.setattr(namespace["subprocess"], "run", lambda argv, **kw: calls.append(argv) or SimpleNamespace(returncode=int(mode == "bad-signature")))
    if mode in ("ok", "absent"):
        result = module["installed_native"]()
        assert (result is not None) == (mode == "ok")
        if result is not None:
            monkeypatch.setattr(os, "execv", lambda *args: calls.append(args))
            monkeypatch.setattr(sys, "argv", [name, "--help"])
            module["main"]()
            assert calls[-1][1][-1] == "--help"
    else:
        with pytest.raises(RuntimeError, match="repair"):
            module["installed_native"]()

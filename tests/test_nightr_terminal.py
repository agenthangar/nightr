"""Unicode clipping and window accounting keep extracted inline rails usable."""
import nightr_terminal as terminal


def test_unicode_width_clip_and_wrap():
    assert terminal.display_width('e\u0301界\u200d') == 3
    assert terminal.clip_columns('hello', 0) == ''
    assert terminal.clip_columns('界ab', 4) == '界ab'
    assert terminal.clip_columns('界abc', 3) == '界…'
    assert terminal.wrap_columns('ab界cd', 4, ' ') == ['ab界', ' cd']
    assert terminal.wrap_columns('', 4) == []
    assert terminal._vis_len('\x1b[36m界\x1b[0m') == 2
    assert terminal._term_rows('界ab', 3) == 2


def test_window_clamps_and_keeps_overflowing_row():
    assert terminal._page_window([], 2, 5) == (0, 0)
    assert terminal._page_window([1, 1], 0, 3) == (0, 2)
    assert terminal._page_window([9, 1, 1], 0, 2) == (0, 1)
    assert terminal._page_window([1, 1, 1, 1], 99, 3) == (2, 4)


def test_platform_key_labels():
    assert terminal.key_labels('Ctrl-c · Alt-x · Enter · Esc · Tab', 'darwin', True) == '⌃C · ⌥X · ↩ · ⎋ · ⇥'
    assert terminal.key_labels('Ctrl-c · Alt-x', 'linux', True) == '^C · M-X'
    assert terminal.key_labels('Ctrl-c · Alt-x', 'linux') == 'Ctrl-C · Alt-X'

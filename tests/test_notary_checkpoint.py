"""Synthetic checkpoint, Apple-response and archive/provenance contracts only."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import zipfile

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import notary_checkpoint as notary

IDENTIFIER = '01234567-0123-0123-0123-0123456789ab'
SHA = 'a' * 40


@pytest.fixture
def checkpoint(tmp_path, monkeypatch):
    for key, value in {'GITHUB_SHA': SHA, 'GITHUB_RUN_ID': '100', 'GITHUB_REPOSITORY': notary.REPOSITORY,
                       'GITHUB_REF': 'refs/heads/main'}.items(): monkeypatch.setenv(key, value)
    result = notary.Checkpoint(tmp_path / 'checkpoint', '0.1.0', 'TEAM123456')
    app = tmp_path / 'app'; app.write_bytes(b'exact submitted signed archive')
    guard = tmp_path / 'guard'; guard.write_bytes(b'signed guard')
    result.retain('app', app); result.retain('guard', guard)
    return result


def responses(checkpoint, status='Accepted', *, timeout=False):
    calls = []
    def run(*arguments, **kwargs):
        calls.append(arguments)
        action = arguments[2]
        if action == 'submit':
            # The signed product is outside any ephemeral build stage already.
            assert Path(arguments[3]).read_bytes() == b'exact submitted signed archive'
            assert notary.bounded_json(checkpoint.directory / 'checkpoint.json')['submissions']['app']['status'] == 'submission_unknown'
            return json.dumps({'id': IDENTIFIER})
        if action == 'wait':
            assert notary.bounded_json(checkpoint.directory / 'checkpoint.json')['submissions']['app']['id'] == IDENTIFIER
            if timeout: raise subprocess.TimeoutExpired('notarytool', 1560)
        if action in ['wait', 'info']: return json.dumps({'id': IDENTIFIER, 'status': status})
        if action == 'log': return json.dumps({'jobId': IDENTIFIER, 'sha256': checkpoint.data['products']['app']['sha256']})
        raise AssertionError(arguments)
    return calls, run


def test_id_is_durable_before_wait_and_exact_bytes_survive(checkpoint):
    calls, run = responses(checkpoint)
    original = checkpoint.path('app').read_bytes()
    checkpoint.notarize('app', 'profile', run)
    checkpoint.notarize('app', 'profile', run)
    assert [call[2] for call in calls].count('submit') == 1
    assert [call[2] for call in calls].count('wait') == 2
    assert checkpoint.path('app').read_bytes() == original
    assert checkpoint.data['submissions']['app']['status'] == 'Accepted'
    assert (checkpoint.directory / 'app-notary.log').is_file()


def test_timeout_remains_pending_and_resume_waits_existing_id(checkpoint, monkeypatch):
    calls, run = responses(checkpoint, status='In Progress', timeout=True)
    with pytest.raises(RuntimeError, match='pending'): checkpoint.notarize('app', 'profile', run)
    assert checkpoint.data['submissions']['app']['status'] == 'pending'
    monkeypatch.setenv('GITHUB_RUN_ID', '101')
    restored = notary.Checkpoint(checkpoint.directory, '0.1.0', 'TEAM123456', resume_run_id='100')
    _, accepted = responses(restored)
    restored.notarize('app', 'profile', accepted)
    assert len([call for call in calls if call[2] == 'submit']) == 1
    assert restored.data['submissions']['app']['id'] == IDENTIFIER


def test_unknown_submission_never_uploads_again(checkpoint):
    calls = []
    def broken(*args, **kwargs):
        calls.append(args)
        raise subprocess.TimeoutExpired('notarytool', 300)
    with pytest.raises(subprocess.TimeoutExpired): checkpoint.notarize('app', 'profile', broken)
    with pytest.raises(RuntimeError, match='outcome unknown'): checkpoint.notarize('app', 'profile', broken)
    assert len(calls) == 1


def test_rejection_retains_log_and_refuses_continuation(checkpoint):
    _, run = responses(checkpoint, status='Invalid')
    with pytest.raises(RuntimeError, match='Invalid'): checkpoint.notarize('app', 'profile', run)
    assert checkpoint.path('app').is_file()
    assert (checkpoint.directory / 'app-notary.log').is_file()


@pytest.mark.parametrize('mutation', ['source', 'team', 'digest', 'extra', 'symlink'])
def test_resume_refuses_changed_provenance_or_products(checkpoint, monkeypatch, mutation):
    if mutation == 'source': monkeypatch.setenv('GITHUB_SHA', 'b' * 40)
    elif mutation == 'team': checkpoint.data['teamID'] = 'OTHER12345'; checkpoint.save()
    elif mutation == 'digest': checkpoint.path('app').write_bytes(b'changed bytes')
    elif mutation == 'extra': (checkpoint.directory / 'signing.p12').write_bytes(b'never accepted')
    else:
        checkpoint.path('app').unlink(); checkpoint.path('app').symlink_to('/tmp/missing')
    monkeypatch.setenv('GITHUB_RUN_ID', '101')
    with pytest.raises((RuntimeError, ValueError)):
        notary.Checkpoint(checkpoint.directory, '0.1.0', 'TEAM123456', resume_run_id='100')


@pytest.mark.parametrize('name,target,descendant', [
    ('../outside', None, None), ('Nightr.app/../outside', None, None),
    ('Nightr.app/link', '../../outside', None), ('Nightr.app/link', 'target', 'Nightr.app/link/child'),
    ('Nightr.app//alias', None, None), ('Nightr.app/link', 'link', None),
])
def test_zip_rejects_traversal_links_and_aliases(tmp_path, name, target, descendant):
    archive = tmp_path / 'app.zip'
    with zipfile.ZipFile(archive, 'w') as output:
        item = zipfile.ZipInfo(name)
        item.external_attr = ((stat.S_IFLNK | 0o777) if target is not None else (stat.S_IFREG | 0o644)) << 16
        output.writestr(item, target or 'data')
        if descendant: output.writestr(descendant, 'data')
    with pytest.raises(RuntimeError): notary.validate_app_zip(archive)


def test_zip_allows_internal_cli_alias(tmp_path):
    archive = tmp_path / 'app.zip'
    with zipfile.ZipFile(archive, 'w') as output:
        output.writestr('Nightr.app/Contents/MacOS/nightr-native', b'signed binary')
        alias = zipfile.ZipInfo('Nightr.app/Contents/MacOS/nightr')
        alias.external_attr = (stat.S_IFLNK | 0o777) << 16
        output.writestr(alias, 'nightr-native')
    notary.validate_app_zip(archive)


@pytest.mark.parametrize('change', ['none', 'sha', 'branch', 'workflow', 'event', 'repository', 'artifact', 'running'])
def test_github_provenance_is_exact_before_archive_processing(change):
    workflow = {'id': 42, 'path': notary.WORKFLOW}
    run = {'id': 100, 'workflow_id': 42, 'path': notary.WORKFLOW, 'event': 'workflow_dispatch', 'head_branch': 'main',
           'head_sha': SHA, 'repository': {'full_name': notary.REPOSITORY}, 'status': 'completed'}
    artifact = {'name': f'nightr-checkpoint-0.1.0-{SHA}-100', 'expired': False, 'workflow_run': {'id': 100}, 'size_in_bytes': 50}
    if change == 'sha': run['head_sha'] = 'b' * 40
    elif change == 'branch': run['head_branch'] = 'feature'
    elif change == 'workflow': run['workflow_id'] = 99
    elif change == 'event': run['event'] = 'pull_request'
    elif change == 'repository': run['repository']['full_name'] = 'other/repo'
    elif change == 'artifact': artifact['name'] = 'arbitrary'
    elif change == 'running': run['status'] = 'in_progress'
    if change == 'none': notary.verify_run(run, workflow, artifact, '0.1.0', '100', SHA)
    else:
        with pytest.raises(RuntimeError, match='provenance'):
            notary.verify_run(run, workflow, artifact, '0.1.0', '100', SHA)


def test_large_accepted_log_preserves_binding_and_bounded_summary(checkpoint):
    _, original = responses(checkpoint)
    def run(*arguments, **kwargs):
        if arguments[2] == 'log':
            return json.dumps({'jobId': IDENTIFIER, 'sha256': checkpoint.data['products']['app']['sha256'],
                               'status': 'Accepted', 'ticketContents': [{'path': 'nested-runtime-binary'}] * 2000})
        return original(*arguments, **kwargs)
    checkpoint.notarize('app', 'profile', run)
    saved = checkpoint.directory / 'app-notary.log'
    assert saved.stat().st_size <= 32768
    assert json.loads(saved.read_text())['ticketCount'] == 2000
    assert checkpoint.data['submissions']['app']['status'] == 'Accepted'


def test_notary_log_product_binding_mismatch_fails_without_resubmission(checkpoint):
    calls, original = responses(checkpoint)
    def run(*arguments, **kwargs):
        if arguments[2] == 'log': return json.dumps({'jobId': IDENTIFIER, 'sha256': 'f' * 64})
        return original(*arguments, **kwargs)
    with pytest.raises(RuntimeError, match='exact submitted product'):
        checkpoint.notarize('app', 'profile', run)
    with pytest.raises(RuntimeError, match='exact submitted product'):
        checkpoint.notarize('app', 'profile', run)
    assert len([call for call in calls if call[2] == 'submit']) == 1


def test_zip_allows_internal_parent_relative_runtime_link(tmp_path):
    archive = tmp_path / 'app.zip'
    with zipfile.ZipFile(archive, 'w') as output:
        output.writestr('Nightr.app/Contents/Resources/runtime/lib/libpython.dylib', b'signed runtime')
        alias = zipfile.ZipInfo('Nightr.app/Contents/Resources/runtime/bin/python-lib')
        alias.external_attr = (stat.S_IFLNK | 0o777) << 16
        output.writestr(alias, '../lib/libpython.dylib')
    notary.validate_app_zip(archive)


@pytest.mark.parametrize('descendant', [False, True])
def test_zip_rejects_case_alias_link_escape(tmp_path, descendant):
    archive = tmp_path / 'app.zip'
    with zipfile.ZipFile(archive, 'w') as output:
        for name, target in [('Nightr.app/a/b/c/Link', '../../../x'),
                             ('Nightr.app/escape', 'a/b/c/link/../../../../outside')]:
            link = zipfile.ZipInfo(name); link.external_attr = (stat.S_IFLNK | 0o777) << 16
            output.writestr(link, target)
        if descendant: output.writestr('Nightr.app/Escape/child', 'must not write through an alias')
    with pytest.raises(RuntimeError): notary.validate_app_zip(archive)


def test_zip_rejects_unicode_equivalent_names(tmp_path):
    archive = tmp_path / 'app.zip'
    with zipfile.ZipFile(archive, 'w') as output:
        output.writestr('Nightr.app/caf\u00e9', 'first')
        output.writestr('Nightr.app/cafe\u0301', 'alias')
    with pytest.raises(RuntimeError): notary.validate_app_zip(archive)


@pytest.mark.skipif(sys.platform != 'darwin', reason='Apple ditto archive contract')
def test_real_ditto_metadata_and_relative_symlinks_roundtrip(tmp_path):
    app = tmp_path / 'source/Nightr.app'
    macos = app / 'Contents/MacOS'; macos.mkdir(parents=True)
    (macos / 'nightr-native').write_bytes(b'nonexecuted fixture bytes')
    (macos / 'nightr').symlink_to('nightr-native')
    runtime = app / 'Contents/Resources/runtime'
    (runtime / 'bin').mkdir(parents=True); (runtime / 'lib').mkdir()
    (runtime / 'lib/python').write_bytes(b'nonexecuted runtime fixture')
    (runtime / 'bin/python').symlink_to('../lib/python')
    subprocess.run(['/usr/bin/xattr', '-w', 'com.apple.metadata:nightr-test', 'synthetic metadata', str(macos / 'nightr-native')], check=True, timeout=30)
    archive = tmp_path / 'Nightr.zip'
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(app), str(archive)], check=True, timeout=30)
    notary.validate_app_zip(archive)
    destination = tmp_path / 'unpacked'
    subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(destination)], check=True, timeout=30)
    restored = destination / 'Nightr.app/Contents'
    assert (restored / 'MacOS/nightr').readlink() == Path('nightr-native')
    assert (restored / 'Resources/runtime/bin/python').readlink() == Path('../lib/python')
    assert subprocess.check_output(['/usr/bin/xattr', '-p', 'com.apple.metadata:nightr-test', str(restored / 'MacOS/nightr-native')], timeout=30).strip() == b'synthetic metadata'

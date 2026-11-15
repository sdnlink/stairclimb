#!/usr/bin/env python3
"""Build Debug/Release and run all XCTest tests on a Mac with Xcode 16+."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import uuid


ROOT = Path(__file__).resolve().parents[1]


class ValidationFailure(RuntimeError):
    pass


def failure_excerpt(text, limit=90):
    """Surface bounded compiler/assertion context without flooding the Actions console."""
    lines = text.splitlines()
    selected = set(range(max(0, len(lines) - 20), len(lines)))
    pattern = re.compile(r'error:|fatal error|Testing failed|Test Case .* failed|Failing tests:', re.I)
    for index, line in enumerate(lines):
        if pattern.search(line):
            selected.update(range(max(0, index - 2), min(len(lines), index + 5)))
    return '\n'.join(lines[index][:1500] for index in sorted(selected)[:limit])


def select_device(inventory, requested=None):
    """Select only available iPhones with an iOS runtime >= our deployment target."""
    candidates = []
    for runtime, devices in inventory.get('devices', {}).items():
        match = re.fullmatch(r'com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+)-(\d+)(?:-(\d+))?', runtime)
        if not match:
            continue
        version = tuple(int(part or 0) for part in match.groups())
        if version < (17, 0, 0):
            continue
        for device in devices:
            device_type = device.get('deviceTypeIdentifier')
            is_iphone = (device_type.startswith('com.apple.CoreSimulator.SimDeviceType.iPhone-')
                         if isinstance(device_type, str) else device.get('name', '').startswith('iPhone'))
            if (device.get('isAvailable') is not True
                    or not is_iphone
                    or not re.fullmatch(r'[0-9a-fA-F-]{36}', device.get('udid', ''))):
                continue
            candidates.append((version, device['udid'], device, runtime))
    if requested:
        candidates = [entry for entry in candidates if entry[1].lower() == requested.lower()]
    if not candidates:
        raise ValidationFailure('No matching available iPhone simulator with iOS 17+. '
                                'Install an iOS runtime in Xcode and run xcrun simctl list devices available.')
    # Newest runtime first; UDID makes ties deterministic. Never boot/delete an unrelated simulator here.
    _, _, device, runtime = sorted(candidates, key=lambda entry: (entry[0], entry[1]))[-1]
    return {'id': device['udid'], 'name': device['name'], 'runtime': runtime}


def source_snapshot(root):
    inputs = list((root/'ios').rglob('*'))
    inputs += [root/path for path in [
        'scripts/validate_apple.py', 'scripts/check_ios_project.py',
        'backend/domain.py', 'backend/src/domain.rs', '.github/workflows/apple.yml',
    ]]
    hashes = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in sorted(inputs) if path.is_file()
              and 'xcuserdata' not in path.parts and path.name != '.DS_Store'}
    try:
        revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root,
                                  text=True, capture_output=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        revision = None
    return {'git_revision': revision, 'sha256': hashes}


def validate(root, output, requested=None):
    if platform.system() != 'Darwin':
        raise ValidationFailure('Apple validation requires macOS with Xcode 16+ and an iOS simulator. '
                                'Linux structure/orchestration checks do not execute Swift or XCTest.')
    for tool in ['xcodebuild', 'xcrun']:
        if not shutil.which(tool):
            raise ValidationFailure(f'Missing {tool}; select a full Xcode installation with xcode-select.')
    if output == root or any(output.is_relative_to(root/directory) for directory in ['ios', 'scripts', 'backend', '.github']):
        raise ValidationFailure('Artifact directory must be outside source directories (use .runtime/apple-validation).')
    # Refuse reuse: never mix a previous success/result bundle with the current run.
    output.mkdir(parents=True, exist_ok=False)
    receipt = {'status': 'running', 'platform': platform.platform(),
               'started_at': datetime.now(timezone.utc).isoformat(),
               'source': source_snapshot(root), 'commands': [],
               'simulator_signing': 'Ad hoc identity (-); no Apple certificate or provisioning profile',
               'limitations': ['Simulator builds use ad hoc signing; no device signing, HealthKit, '
                               'system certificate trust or visual interaction is verified.']}

    def save():
        (output/'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')

    def run(name, command):
        log = output/f'{name}.log'
        entry = {'name': name, 'argv': command, 'log': str(log), 'exit_status': None}
        receipt['commands'].append(entry)
        save()
        print(f'$ {shlex.join(command)}', flush=True)
        with log.open('w') as stream:
            stream.write('$ ' + shlex.join(command) + '\n')
            stream.flush()
            result = subprocess.run(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT)
        entry['exit_status'] = result.returncode
        save()
        print(f'{name}: exit {result.returncode}; {log}', flush=True)
        if result.returncode:
            print(f'Failure details from {log.name}:', flush=True)
            print(failure_excerpt(log.read_text(errors='replace')), flush=True)
            raise ValidationFailure(f'{name} failed with exit {result.returncode}; see {log}')
        return log.read_text()

    try:
        run('structure', [sys.executable, str(root/'scripts/check_ios_project.py')])
        version = run('xcode-version', ['xcodebuild', '-version'])
        match = re.search(r'^Xcode (\d+)', version, re.M)
        if not match or int(match[1]) < 16:
            raise ValidationFailure('Xcode 16+ is required; see xcode-version.log.')
        device_log = run('simulators', ['xcrun', 'simctl', 'list', 'devices', 'available', '--json'])
        # The first line of every log records argv; the remaining output is the tool's JSON.
        device = select_device(json.loads(device_log.split('\n', 1)[1]), requested)
        receipt['simulator'] = device
        common = ['xcodebuild', '-project', str(root/'ios/StairClimb.xcodeproj'),
                  '-scheme', 'StairClimb', '-derivedDataPath', str(output/'DerivedData'),
                  # A hosted XCTest exercising real Keychain needs a signed app.
                  # Simulator ad hoc signing uses no Apple developer credentials.
                  'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-',
                  'AD_HOC_CODE_SIGNING_ALLOWED=YES']
        for configuration in ['Debug', 'Release']:
            run(f'build-{configuration.lower()}', common + [
                '-configuration', configuration, '-destination', 'generic/platform=iOS Simulator', 'build'])
        bundle = output/'Tests.xcresult'
        try:
            run('xctest', common + ['-configuration', 'Debug', '-destination',
                                   f'platform=iOS Simulator,id={device["id"]}',
                                   '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(bundle), 'test'])
        except ValidationFailure:
            # xcodebuild returns 65 for failed assertions too. Preserve the original
            # failure, but extract the result bundle before returning to Actions.
            if bundle.is_dir():
                try:
                    summary_log = run('test-summary', ['xcrun', 'xcresulttool', 'get', 'test-results',
                                                      'summary', '--path', str(bundle)])
                    failed_summary = json.loads(summary_log.split('\n', 1)[1])
                    if not isinstance(failed_summary, dict):
                        raise ValueError('XCTest summary must be an object')
                    receipt['tests'] = {key: failed_summary.get(key) for key in [
                        'totalTestCount', 'passedTests', 'failedTests', 'skippedTests']}
                    receipt['test_failures'] = failed_summary.get('testFailures', [])
                    print('XCTest result summary:', json.dumps(failed_summary, ensure_ascii=False)[:16000], flush=True)
                except (ValidationFailure, OSError, ValueError) as diagnostic_error:
                    receipt['diagnostic_error'] = str(diagnostic_error)
                    print('Could not read failed XCTest result:', diagnostic_error, flush=True)
            raise
        if not bundle.is_dir():
            raise ValidationFailure('xcodebuild produced no Tests.xcresult bundle.')
        summary_log = run('test-summary', ['xcrun', 'xcresulttool', 'get', 'test-results',
                                          'summary', '--path', str(bundle)])
        summary = json.loads(summary_log.split('\n', 1)[1])
        counts = {key: summary.get(key) for key in ['totalTestCount', 'passedTests', 'failedTests', 'skippedTests']}
        if (any(type(value) is not int for value in counts.values())
                or counts['passedTests'] <= 0 or counts['failedTests'] != 0 or counts['skippedTests'] != 0
                or counts['totalTestCount'] != counts['passedTests']):
            raise ValidationFailure('XCTest summary must contain nonzero passed tests, no failures/skips; '
                                    'see test-summary.log.')
        receipt['tests'] = counts
        if source_snapshot(root) != receipt['source']:
            raise ValidationFailure('Validation inputs changed during this run; rerun on a stable source tree.')
        receipt['status'] = 'passed'
    except (ValidationFailure, OSError, ValueError) as error:
        receipt['status'] = 'failed'
        receipt['error'] = str(error)
        raise ValidationFailure(str(error)) from error
    finally:
        receipt['finished_at'] = datetime.now(timezone.utc).isoformat()
        save()
    print(f'PASS: Debug/Release builds and {counts["passedTests"]} XCTest tests; {output}', flush=True)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device-id', help='UDID of an available iPhone simulator (otherwise newest iOS >=17)')
    parser.add_argument('--output', type=Path, help='New artifact directory; must not already exist')
    args = parser.parse_args()
    output = (args.output or ROOT/'.runtime/apple-validation'/
              (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8])).resolve()
    try:
        validate(ROOT, output, args.device_id)
    except (ValidationFailure, OSError) as error:
        parser.exit(2, f'FAIL: {error}\n')


if __name__ == '__main__':
    main()

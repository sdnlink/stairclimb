#!/usr/bin/env python3
"""Archive an unsigned iPhoneOS Release app and package it as a clearly labelled IPA."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]


class PackageFailure(RuntimeError):
    pass


def inspect_app(app):
    try:
        with (app / 'Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise PackageFailure('Archive has no readable application Info.plist') from error
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise PackageFailure('Only a device iPhoneOS app can be packaged; simulator apps are rejected')
    executable = info.get('CFBundleExecutable')
    if (not isinstance(executable, str) or not executable or Path(executable).name != executable
            or not (app / executable).is_file() or (app / executable).is_symlink()):
        raise PackageFailure('Archive executable is missing or invalid')
    if not isinstance(info.get('CFBundleIdentifier'), str) or not info['CFBundleIdentifier']:
        raise PackageFailure('Archive bundle identifier is missing')
    if (app / 'embedded.mobileprovision').exists() or (app / '_CodeSignature').exists():
        raise PackageFailure('Unsigned packaging refuses provisioned or signed application input')
    return info


def build(root, output):
    root, output = Path(root).resolve(), Path(output).resolve()
    if platform.system() != 'Darwin':
        raise PackageFailure('IPA compilation requires macOS with full Xcode 16+; Linux cannot compile iOS')
    for tool in ['xcodebuild', 'xcrun', 'ditto']:
        if not shutil.which(tool):
            raise PackageFailure('Missing Apple tool: ' + tool)
    if output == root or any(output.is_relative_to(root / name) for name in ['ios', 'scripts', 'backend', '.github', '.git']):
        raise PackageFailure('Use a new artifact directory outside source directories')
    output.mkdir(parents=True, exist_ok=False)
    receipt = {'status': 'running', 'signed': False, 'installable': False,
               'started_at': datetime.now(timezone.utc).isoformat(), 'commands': [],
               'limitation': 'Unsigned device IPA only; not installable, not exported for App Store/TestFlight, not uploaded.'}
    ipa = output / 'StairClimb-unsigned.ipa'

    def save():
        (output / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')

    def run(name, args, cwd=None):
        entry = {'name': name, 'argv': args, 'exit_status': None}
        receipt['commands'].append(entry)
        save()
        with (output / (name + '.log')).open('w') as log:
            result = subprocess.run(args, cwd=cwd or root, stdout=log, stderr=subprocess.STDOUT)
        entry['exit_status'] = result.returncode
        save()
        if result.returncode:
            raise PackageFailure(name + ' failed; see ' + name + '.log')
        return (output / (name + '.log')).read_text()

    try:
        revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root, capture_output=True, text=True, check=True)
        receipt['git_revision'] = revision.stdout.strip()
        version = run('xcode-version', ['xcodebuild', '-version'])
        import re
        match = re.search(r'^Xcode (\d+)', version, re.M)
        if not match or int(match[1]) < 16:
            raise PackageFailure('Xcode 16+ is required')
        archive = output / 'StairClimb.xcarchive'
        run('archive', ['xcodebuild', '-project', str(root / 'ios/StairClimb.xcodeproj'),
            '-scheme', 'StairClimb', '-configuration', 'Release', '-sdk', 'iphoneos',
            '-destination', 'generic/platform=iOS', '-archivePath', str(archive),
            '-derivedDataPath', str(output / 'DerivedData'),
            '-resultBundlePath', str(output / 'Archive.xcresult'),
            'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=',
            'SKIP_INSTALL=NO', 'archive'])
        app = archive / 'Products/Applications/StairClimb.app'
        info = inspect_app(app)
        architectures = run('architectures', ['xcrun', 'lipo', '-archs', str(app / info['CFBundleExecutable'])]).strip().split()
        if 'arm64' not in architectures or any(arch not in ['arm64', 'arm64e'] for arch in architectures):
            raise PackageFailure('Archive must contain only iPhone arm64 device architectures')
        payload = output / 'Package/Payload'
        payload.mkdir(parents=True)
        shutil.copytree(app, payload / 'StairClimb.app', symlinks=True)
        run('package', ['ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', 'Payload', str(ipa)], cwd=payload.parent)
        with zipfile.ZipFile(ipa) as package:
            if package.testzip() is not None or 'Payload/StairClimb.app/Info.plist' not in package.namelist():
                raise PackageFailure('IPA archive is corrupt or missing Payload/StairClimb.app')
        digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
        (output / 'StairClimb-unsigned.ipa.sha256').write_text(digest + '  ' + ipa.name + '\n')
        receipt.update(status='passed', ipa=ipa.name, sha256=digest, architectures=architectures,
                       bundle_id=info['CFBundleIdentifier'], version=info.get('CFBundleShortVersionString'),
                       build=info.get('CFBundleVersion'))
    except (PackageFailure, OSError, ValueError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        receipt.update(status='failed', error=str(error))
        ipa.unlink(missing_ok=True)
        raise PackageFailure(str(error)) from error
    finally:
        receipt['finished_at'] = datetime.now(timezone.utc).isoformat()
        save()
    print('PASS: unsigned device IPA packaged; not installable: ' + str(ipa))
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / '.runtime/ipa' /
                        (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]))
    args = parser.parse_args()
    try:
        build(ROOT, args.output)
    except (PackageFailure, OSError) as error:
        parser.exit(2, 'FAIL: ' + str(error) + '\n')


if __name__ == '__main__':
    main()

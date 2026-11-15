#!/usr/bin/env python3
"""Sign/archive/export on an ephemeral macOS runner using repository signing secrets."""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import secrets
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


class SigningFailure(RuntimeError):
    pass


def secret(*names):
    for name in names:
        value = os.environ.get(name, '')
        if value.strip():
            return value
    raise SigningFailure('Missing signing configuration: ' + ' or '.join(names))


def material(mode):
    if mode == 'development':
        return (secret('DEV_CERTIFICATE_P12', 'BUILD_CERTIFICATE_P12'),
                secret('DEV_P12_PASSWORD', 'P12_PASSWORD'),
                secret('DEV_PROVISION_PROFILE', 'BUILD_PROVISION_PROFILE'))
    return (secret('DIST_CERTIFICATE_P12', 'BUILD_CERTIFICATE_P12'),
            secret('DIST_P12_PASSWORD', 'P12_PASSWORD'),
            secret('DIST_PROVISION_PROFILE', 'BUILD_PROVISION_PROFILE'))


def decode_file(value, path):
    try:
        data = base64.b64decode(''.join(value.split()), validate=True)
    except ValueError as error:
        raise SigningFailure('Certificate and provisioning profile must be base64 encoded') from error
    if not data:
        raise SigningFailure('Signing material is empty')
    path.write_bytes(data)
    path.chmod(0o600)


def validate_profile(profile, team, mode, now=None):
    now = now or datetime.now(timezone.utc)
    expiry = profile.get('ExpirationDate')
    if not isinstance(expiry, datetime):
        raise SigningFailure('Provisioning profile has no expiry')
    if expiry.replace(tzinfo=timezone.utc) <= now:
        raise SigningFailure('Provisioning profile has expired')
    entitlements = profile.get('Entitlements', {})
    if team not in profile.get('TeamIdentifier', []) or entitlements.get('com.apple.developer.team-identifier') != team:
        raise SigningFailure('Provisioning profile does not match APPLE_TEAM_ID')
    prefixes = profile.get('ApplicationIdentifierPrefix', [])
    identifier = entitlements.get('application-identifier', '')
    prefix = next((item + '.' for item in prefixes if isinstance(item, str) and identifier.startswith(item + '.')), None)
    bundle = identifier[len(prefix):] if prefix else ''
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle):
        raise SigningFailure('Profile must contain an explicit App ID, not a wildcard')
    if entitlements.get('com.apple.developer.healthkit') is not True:
        raise SigningFailure('Profile must enable the HealthKit capability for this App ID')
    if profile.get('ProvisionsAllDevices'):
        raise SigningFailure('Enterprise profiles are not supported by these export modes')
    debug = entitlements.get('get-task-allow') is True
    devices = bool(profile.get('ProvisionedDevices'))
    if mode == 'development' and not (debug and devices):
        raise SigningFailure('Development mode requires a development profile with registered devices')
    if mode == 'ad-hoc' and not (not debug and devices):
        raise SigningFailure('Ad Hoc mode requires a distribution profile with registered devices')
    if mode == 'app-store' and (debug or devices):
        raise SigningFailure('App Store mode requires an App Store distribution profile')
    identifier = profile.get('UUID', '')
    if not re.fullmatch(r'[0-9A-Fa-f-]{36}', identifier):
        raise SigningFailure('Profile UUID is invalid')
    return bundle, identifier


def validate_signed_entitlements(entitlements, profile, team, mode):
    """A capable profile alone is insufficient: validate the final app signature."""
    bundle, _ = validate_profile(profile, team, mode)
    expected_identifier = profile['Entitlements']['application-identifier']
    if entitlements.get('com.apple.developer.healthkit') is not True:
        raise SigningFailure('Exported IPA signature is missing the HealthKit entitlement')
    if entitlements.get('application-identifier') != expected_identifier:
        raise SigningFailure('Exported IPA signature App ID does not match its provisioning profile')
    if entitlements.get('com.apple.developer.team-identifier') != team:
        raise SigningFailure('Exported IPA signature does not match APPLE_TEAM_ID')
    if (entitlements.get('get-task-allow') is True) != (mode == 'development'):
        raise SigningFailure('Exported IPA debug entitlement does not match the signing mode')
    return bundle


def build(mode, output):
    if platform.system() != 'Darwin':
        raise SigningFailure('Signed IPA compilation requires macOS with full Xcode 16+')
    for tool in ['xcodebuild', 'security', 'xcrun', 'codesign', 'ditto']:
        if not shutil.which(tool):
            raise SigningFailure('Missing Apple tool: ' + tool)
    output = Path(output).resolve()
    if output == ROOT or any(output.is_relative_to(ROOT/name) for name in ['ios', 'scripts', 'backend', '.github', '.git']):
        raise SigningFailure('Use a new artifact directory outside source directories')
    output.mkdir(parents=True, exist_ok=False)
    receipt = {'status': 'running', 'signed': True, 'mode': mode,
               'started_at': datetime.now(timezone.utc).isoformat(), 'commands': [],
               'uploaded_to_apple': False, 'device_install_verified': False}
    keychain = None
    old_keychains = None
    installed_profiles = []
    package_directory = output/'Export'

    def save():
        (output/'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2)+'\n')

    def private(args, operation):
        # Secret-bearing commands are never included in logs or receipt argv.
        result = subprocess.run(args, capture_output=True)
        if result.returncode:
            raise SigningFailure(operation+' failed (private diagnostics suppressed)')
        return result.stdout

    def run(name, args):
        entry = {'name': name, 'exit_status': None}
        receipt['commands'].append(entry)
        save()
        with (output/(name+'.log')).open('w') as log:
            result = subprocess.run(args, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        entry['exit_status'] = result.returncode
        save()
        if result.returncode:
            raise SigningFailure(name+' failed; see '+name+'.log')
        return (output/(name+'.log')).read_text()

    try:
        team = secret('APPLE_TEAM_ID').strip()
        if not re.fullmatch('[A-Z0-9]{10}', team):
            raise SigningFailure('APPLE_TEAM_ID must be a 10-character Apple team identifier')
        certificate, password, provision = material(mode)
        receipt['git_revision'] = private(['git','rev-parse','HEAD'], 'Read source revision').decode().strip()
        version = run('xcode-version',['xcodebuild','-version'])
        match = re.search(r'^Xcode (\d+)', version, re.M)
        if not match or int(match[1]) < 16:
            raise SigningFailure('Xcode 16+ is required')
        with tempfile.TemporaryDirectory(prefix='stairclimb-sign-', dir=os.environ.get('RUNNER_TEMP')) as temp:
            temp = Path(temp)
            temp.chmod(0o700)
            p12, mobile = temp/'certificate.p12', temp/'profile.mobileprovision'
            decode_file(certificate,p12); decode_file(provision,mobile)
            profile = plistlib.loads(private(['security','cms','-D','-i',str(mobile)],'Decode provisioning profile'))
            bundle, profile_uuid = validate_profile(profile,team,mode)
            receipt['bundle_id'] = bundle
            # Xcode 16+ uses the Developer location; retain compatibility with
            # tools that still search the legacy MobileDevice location.
            for relative in ['Library/Developer/Xcode/UserData/Provisioning Profiles',
                             'Library/MobileDevice/Provisioning Profiles']:
                profiles = Path.home()/relative
                profiles.mkdir(parents=True,exist_ok=True)
                installed_profile = profiles/(profile_uuid+'.mobileprovision')
                original_profile = installed_profile.read_bytes() if installed_profile.exists() else None
                installed_profiles.append((installed_profile,original_profile))
                shutil.copyfile(mobile, installed_profile); installed_profile.chmod(0o600)
            # Keep the private keychain outside TemporaryDirectory: it is deleted in finally,
            # including on archive/export failure, before removing its containing files.
            keychain = output.parent/('signing-'+secrets.token_hex(12)+'.keychain-db')
            key_password = secrets.token_urlsafe(32)
            old_keychains = re.findall(r'"([^"]+)"', private(['security','list-keychains','-d','user'],'Read keychain search list').decode())
            private(['security','create-keychain','-p',key_password,str(keychain)],'Create ephemeral keychain')
            private(['security','set-keychain-settings','-lut','21600',str(keychain)],'Configure ephemeral keychain')
            private(['security','unlock-keychain','-p',key_password,str(keychain)],'Unlock ephemeral keychain')
            private(['security','import',str(p12),'-P',password,'-T','/usr/bin/codesign','-T','/usr/bin/security','-t','cert','-f','pkcs12','-k',str(keychain)],'Import signing certificate')
            private(['security','set-key-partition-list','-S','apple-tool:,apple:,codesign:','-s','-k',key_password,str(keychain)],'Allow codesign private key access')
            private(['security','list-keychains','-d','user','-s',str(keychain),*old_keychains],'Select ephemeral signing keychain')
            identities = private(['security','find-identity','-v','-p','codesigning',str(keychain)],'Read signing identities').decode()
            matches = re.findall(r'\b([0-9A-Fa-f]{40})\s+"([^"\n]+)"',identities)
            expected = ('Apple Development:', 'iPhone Developer:') if mode=='development' else ('Apple Distribution:', 'iPhone Distribution:')
            identities = [fingerprint for fingerprint,name in matches if name.startswith(expected)]
            if len(identities)!=1:
                raise SigningFailure('P12 must contain exactly one valid identity for the selected signing mode')
            identity = identities[0]
            archive = output/'StairClimb.xcarchive'
            run('archive',['xcodebuild','-project',str(ROOT/'ios/StairClimb.xcodeproj'),'-scheme','StairClimb',
                '-configuration','Release','-sdk','iphoneos','-destination','generic/platform=iOS',
                '-archivePath',str(archive),'-derivedDataPath',str(output/'DerivedData'),
                '-resultBundlePath',str(output/'Archive.xcresult'),
                'DEVELOPMENT_TEAM='+team,'PRODUCT_BUNDLE_IDENTIFIER='+bundle,
                'CODE_SIGN_STYLE=Manual','CODE_SIGN_IDENTITY='+identity,
                'PROVISIONING_PROFILE_SPECIFIER='+profile_uuid,'SKIP_INSTALL=NO','archive'])
            options = temp/'ExportOptions.plist'
            method = {'development':'debugging','ad-hoc':'release-testing','app-store':'app-store-connect'}[mode]
            options.write_bytes(plistlib.dumps({'method':method,'teamID':team,'signingStyle':'manual',
                'signingCertificate':identity,'provisioningProfiles':{bundle:profile_uuid},
                'destination':'export','manageAppVersionAndBuildNumber':False,'stripSwiftSymbols':True}))
            options.chmod(0o600)
            run('export',['xcodebuild','-exportArchive','-archivePath',str(archive),
                '-exportPath',str(package_directory),'-exportOptionsPlist',str(options)])
            ipas=list(package_directory.glob('*.ipa'))
            if len(ipas)!=1:
                raise SigningFailure('Export must produce exactly one IPA')
            # Validate what will actually be installed, after Xcode export has
            # selected/re-signed the profile, rather than checking only the archive.
            exported = temp/'exported-app'
            private(['ditto','-x','-k',str(ipas[0]),str(exported)],'Inspect exported IPA')
            applications = list((exported/'Payload').glob('*.app'))
            if len(applications) != 1:
                raise SigningFailure('Exported IPA must contain exactly one application')
            application = applications[0]
            run('codesign-verify',['codesign','--verify','--deep','--strict',str(application)])
            entitlements = plistlib.loads(private(['codesign','-d','--entitlements',':-',str(application)],
                                                  'Read exported application entitlements'))
            exported_profile = plistlib.loads(private(['security','cms','-D','-i',str(application/'embedded.mobileprovision')],
                                                      'Read exported provisioning profile'))
            if validate_signed_entitlements(entitlements,exported_profile,team,mode) != bundle:
                raise SigningFailure('Exported IPA bundle does not match the archive')
            with (application/'Info.plist').open('rb') as stream:
                exported_info = plistlib.load(stream)
            if exported_info.get('CFBundleIdentifier') != bundle:
                raise SigningFailure('Exported IPA Info.plist does not match its signing identity')
            receipt.update(healthkit_entitlement_verified=True, exported_signature_verified=True)
            target = output/('StairClimb-'+mode+'.ipa')
            shutil.copyfile(ipas[0],target)
            digest=hashlib.sha256(target.read_bytes()).hexdigest()
            (output/(target.name+'.sha256')).write_text(digest+'  '+target.name+'\n')
            receipt.update(status='passed',ipa=target.name,sha256=digest,
                           install_scope='Registered devices in profile' if mode!='app-store' else 'App Store/TestFlight distribution only')
    except (SigningFailure,OSError,ValueError,plistlib.InvalidFileException) as error:
        receipt.update(status='failed',error=str(error))
        for item in output.glob('*.ipa*'):
            item.unlink(missing_ok=True)
        raise SigningFailure(str(error)) from error
    finally:
        # Avoid leaking certificates, profiles or keychain files into uploaded artifacts.
        cleanup_failed = False
        if old_keychains is not None:
            result = subprocess.run(['security','list-keychains','-d','user','-s',*old_keychains],capture_output=True)
            cleanup_failed |= result.returncode != 0
        if keychain is not None and keychain.exists():
            result = subprocess.run(['security','delete-keychain',str(keychain)],capture_output=True)
            cleanup_failed |= result.returncode != 0
        for installed_profile,original_profile in installed_profiles:
            if original_profile is None:
                installed_profile.unlink(missing_ok=True)
            else:
                installed_profile.write_bytes(original_profile)
                installed_profile.chmod(0o600)
        receipt['finished_at']=datetime.now(timezone.utc).isoformat()
        receipt['signing_cleanup_passed']=not cleanup_failed
        if cleanup_failed:
            receipt.update(status='failed',error='Signing cleanup failed')
        save()
        if cleanup_failed:
            raise SigningFailure('Signing cleanup failed; do not reuse this runner')
    print('PASS: signed IPA exported; no Apple upload: '+str(target))
    return receipt


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode',choices=['development','ad-hoc','app-store'],required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    try: build(args.mode,args.output)
    except (SigningFailure,OSError) as error: parser.exit(2,'FAIL: '+str(error)+'\n')


if __name__=='__main__': main()

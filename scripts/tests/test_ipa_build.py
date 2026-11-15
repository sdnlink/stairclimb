"""Packaging/profile validation and fake-tool cleanup tests; never compile/sign iOS on Linux."""
import base64
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_ipa as unsigned
import build_signed_ipa as signed

TEAM = 'ABCDE12345'
PROFILE_ID = '12345678-1234-1234-1234-123456789ABC'
PASSWORD = 'fixture-password-not-a-real-secret'


def profile(mode='ad-hoc'):
    value = {'UUID': PROFILE_ID, 'TeamIdentifier':[TEAM], 'ApplicationIdentifierPrefix':[TEAM],
        'ExpirationDate':datetime.now(timezone.utc).replace(tzinfo=None)+timedelta(days=30),
        'Entitlements': {'application-identifier':TEAM+'.cn.stairclimb.app',
                         'com.apple.developer.team-identifier':TEAM,
                         'get-task-allow':mode=='development'}}
    if mode!='app-store': value['ProvisionedDevices']=['fake-device']
    return value


class IPAValidationTests(unittest.TestCase):
    def test_profiles_reject_wrong_team_expiry_capability_wildcard_and_mode(self):
        for mode in ['development','ad-hoc','app-store']:
            value=profile(mode)
            self.assertEqual(signed.validate_profile(value,TEAM,mode),('cn.stairclimb.app',PROFILE_ID))
        invalid=[]
        value=profile();value['ExpirationDate']=datetime(2000,1,1);invalid.append(value)
        value=profile();value['TeamIdentifier']=['WRONG12345'];invalid.append(value)
        value=profile();value['Entitlements']['application-identifier']=TEAM+'.*';invalid.append(value)
        value=profile();value['ProvisionsAllDevices']=True;invalid.append(value)
        value=profile();value['UUID']='../../other';invalid.append(value)
        for value in invalid:
            with self.subTest(value=value),self.assertRaises(signed.SigningFailure):
                signed.validate_profile(value,TEAM,'ad-hoc')
        with self.assertRaises(signed.SigningFailure):
            signed.validate_profile(profile('development'),TEAM,'ad-hoc')
        with self.assertRaises(signed.SigningFailure):
            signed.validate_profile(profile('ad-hoc'),TEAM,'app-store')

    def test_exported_signature_must_match_identity_debug_mode_and_omit_healthkit(self):
        for mode in ['development','ad-hoc','app-store']:
            value=profile(mode)
            entitlements=dict(value['Entitlements'])
            self.assertEqual(signed.validate_signed_entitlements(entitlements,value,TEAM,mode),'cn.stairclimb.app')
            for field,replacement in [('com.apple.developer.healthkit',True),
                    ('application-identifier',TEAM+'.other.app'),
                    ('com.apple.developer.team-identifier','WRONG12345'),
                    ('get-task-allow',mode!='development')]:
                changed=dict(entitlements);changed[field]=replacement
                with self.subTest(mode=mode,field=field),self.assertRaises(signed.SigningFailure):
                    signed.validate_signed_entitlements(changed,value,TEAM,mode)

    def test_selected_profile_secret_is_explicit_and_specific_profile_takes_priority(self):
        with patch.dict(os.environ, {'BUILD_PROVISION_PROFILE': 'fallback'}, clear=True):
            self.assertEqual(signed.provisioning_profile_source('development'), 'BUILD_PROVISION_PROFILE')
            with patch.dict(os.environ, {'DEV_PROVISION_PROFILE': 'specific'}):
                self.assertEqual(signed.provisioning_profile_source('development'), 'DEV_PROVISION_PROFILE')
            with patch.dict(os.environ, {'DIST_PROVISION_PROFILE': 'specific'}):
                self.assertEqual(signed.provisioning_profile_source('ad-hoc'), 'DIST_PROVISION_PROFILE')
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(signed.SigningFailure):
            signed.provisioning_profile_source('development')

    def test_profile_without_healthkit_supports_core_motion(self):
        value = profile('development')
        self.assertNotIn('com.apple.developer.healthkit', value['Entitlements'])
        self.assertEqual(signed.validate_profile(value, TEAM, 'development')[0], 'cn.stairclimb.app')

    def test_material_fallback_and_missing_credentials(self):
        with patch.dict(os.environ,{'BUILD_CERTIFICATE_P12':'base-cert','BUILD_PROVISION_PROFILE':'base-profile',
                                    'P12_PASSWORD':'base-password'},clear=True):
            self.assertEqual(signed.material('ad-hoc'),('base-cert','base-password','base-profile'))
            with patch.dict(os.environ,{'DIST_CERTIFICATE_P12':'dist','DIST_P12_PASSWORD':'dist-pwd','DIST_PROVISION_PROFILE':'dist-profile'}):
                self.assertEqual(signed.material('ad-hoc'),('dist','dist-pwd','dist-profile'))
            self.assertEqual(signed.material('development'),('base-cert','base-password','base-profile'))
        with patch.dict(os.environ,{},clear=True),self.assertRaises(signed.SigningFailure): signed.material('ad-hoc')

    def test_unsigned_package_rejects_simulator_and_signed_apps(self):
        with tempfile.TemporaryDirectory() as temp:
            app=Path(temp)/'StairClimb.app';app.mkdir()
            info={'CFBundleSupportedPlatforms':['iPhoneOS'],'CFBundleExecutable':'StairClimb','CFBundleIdentifier':'cn.stairclimb.app'}
            (app/'StairClimb').write_bytes(b'fixture, not a real executable')
            (app/'Info.plist').write_bytes(plistlib.dumps(info))
            self.assertEqual(unsigned.inspect_app(app)['CFBundleIdentifier'],'cn.stairclimb.app')
            info['CFBundleSupportedPlatforms']=['iPhoneSimulator']
            (app/'Info.plist').write_bytes(plistlib.dumps(info))
            with self.assertRaises(unsigned.PackageFailure):unsigned.inspect_app(app)
            info['CFBundleSupportedPlatforms']=['iPhoneOS'];(app/'Info.plist').write_bytes(plistlib.dumps(info))
            (app/'_CodeSignature').mkdir()
            with self.assertRaises(unsigned.PackageFailure):unsigned.inspect_app(app)

    def test_non_mac_never_starts_or_creates_artifact_directory(self):
        with tempfile.TemporaryDirectory() as temp,patch('platform.system',return_value='Linux'):
            out=Path(temp)/'out'
            with self.assertRaises(signed.SigningFailure):signed.build('ad-hoc',out)
            with self.assertRaises(unsigned.PackageFailure):unsigned.build(Path(temp),out)
            self.assertFalse(out.exists())


class SigningLifecycleTests(unittest.TestCase):
    def exercise(self, fail_archive=False, mode='ad-hoc', unexpected_healthkit=False):
        with tempfile.TemporaryDirectory() as temp:
            temp=Path(temp);out=temp/'artifacts';fake_home=temp/'home';fake_home.mkdir()
            profiles=fake_home/'Library/MobileDevice/Provisioning Profiles';profiles.mkdir(parents=True)
            existing=profiles/(PROFILE_ID+'.mobileprovision');existing.write_bytes(b'original profile')
            prefix='DEV' if mode=='development' else 'DIST'
            env={'APPLE_TEAM_ID':TEAM,prefix+'_CERTIFICATE_P12':base64.b64encode(b'fake certificate').decode(),
                prefix+'_PROVISION_PROFILE':base64.b64encode(b'fake profile').decode(),
                prefix+'_P12_PASSWORD':PASSWORD,'RUNNER_TEMP':str(temp)}
            calls=[]
            def fake_run(args,**kwargs):
                calls.append(args)
                tool=args[0];stdout=b'';code=0
                if tool=='git':stdout=b'fixture-revision\n'
                elif tool=='security':
                    if args[1:3]==['cms','-D']:stdout=plistlib.dumps(profile(mode))
                    elif args[1:3]==['list-keychains','-d'] and '-s' not in args:stdout=b'"/original.keychain-db"\n'
                    elif args[1]=='create-keychain':Path(args[-1]).write_bytes(b'fake keychain')
                    elif args[1]=='delete-keychain':Path(args[-1]).unlink()
                    elif args[1]=='find-identity':
                        kind='Apple Development' if mode=='development' else 'Apple Distribution'
                        stdout=('1) '+'A'*40+' "'+kind+': Fixture"\n').encode()
                elif tool=='ditto':
                    application=Path(args[-1])/'Payload/StairClimb.app';application.mkdir(parents=True)
                    (application/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'cn.stairclimb.app'}))
                elif tool=='codesign' and '-d' in args:
                    entitlements=dict(profile(mode)['Entitlements'])
                    if unexpected_healthkit:entitlements['com.apple.developer.healthkit']=True
                    stdout=plistlib.dumps(entitlements)
                elif tool=='xcodebuild':
                    if args[1:]==['-version']:stdout=b'Xcode 16.4\nBuild version fixture\n'
                    elif 'archive'==args[-1]:code=65 if fail_archive else 0
                    elif '-exportArchive' in args:
                        destination=Path(args[args.index('-exportPath')+1]);destination.mkdir()
                        (destination/'StairClimb.ipa').write_bytes(b'fixture signed export, not real IPA')
                if hasattr(kwargs.get('stdout'),'write'):kwargs['stdout'].write(stdout.decode())
                return subprocess.CompletedProcess(args,code,stdout=stdout.decode() if kwargs.get('text') else stdout,stderr=b'')
            with patch.dict(os.environ,env,clear=True),patch('platform.system',return_value='Darwin'),patch('shutil.which',return_value='/fake/tool'),patch('build_signed_ipa.ROOT',temp),patch('pathlib.Path.home',return_value=fake_home),patch('subprocess.run',side_effect=fake_run):
                if fail_archive or unexpected_healthkit:
                    with self.assertRaises(signed.SigningFailure):signed.build(mode,out)
                else:
                    receipt=signed.build(mode,out)
                    self.assertEqual(receipt['status'],'passed')
                    self.assertFalse(receipt['uploaded_to_apple'])
                    self.assertTrue((out/('StairClimb-'+mode+'.ipa.sha256')).exists())
                    self.assertTrue(receipt['no_healthkit_entitlement_verified'])
                    self.assertTrue(receipt['exported_signature_verified'])
            self.assertEqual(existing.read_bytes(),b'original profile')
            self.assertEqual(list((fake_home/'Library/Developer/Xcode/UserData/Provisioning Profiles').glob('*.mobileprovision')),[])
            self.assertEqual(list(temp.glob('*.keychain-db')),[])
            self.assertTrue(any(call[:2]==['security','delete-keychain'] for call in calls))
            self.assertTrue(any(call==['security','list-keychains','-d','user','-s','/original.keychain-db'] for call in calls))
            for file in out.glob('*'):
                if file.is_file():self.assertNotIn(PASSWORD,file.read_text(errors='replace'))
            receipt=json.loads((out/'receipt.json').read_text())
            self.assertEqual(receipt['status'],'failed' if fail_archive or unexpected_healthkit else 'passed')
            self.assertTrue(receipt['signing_cleanup_passed'])
            if fail_archive or unexpected_healthkit:self.assertEqual(list(out.glob('*.ipa')),[])

    def test_success_cleans_signing_material_and_does_not_log_password(self):self.exercise()
    def test_archive_failure_cleans_keychain_restores_profile_and_keeps_failure_receipt(self):self.exercise(True)
    def test_development_mode_uses_development_identity_and_verifies_exported_motion_signature(self):self.exercise(mode='development')
    def test_unexpected_exported_healthkit_rejects_artifact_and_cleans_signing_files(self):self.exercise(unexpected_healthkit=True)


if __name__=='__main__':unittest.main()

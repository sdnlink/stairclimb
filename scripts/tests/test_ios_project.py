"""Regression tests prove the static check rejects real broken project wiring."""
from pathlib import Path
import ipaddress
import plistlib
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_ios_project import CheckFailure, check_project, openstep


class IOSProjectChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source = Path(__file__).resolve().parents[2]
        shutil.copytree(source/'ios', self.root/'ios')
        (self.root/'backend').mkdir()
        shutil.copyfile(source/'backend/domain.py', self.root/'backend/domain.py')
        (self.root/'backend/src').mkdir()
        shutil.copyfile(source/'backend/src/domain.rs', self.root/'backend/src/domain.rs')
        self.project = self.root/'ios/StairClimb.xcodeproj/project.pbxproj'

    def replace(self, path, before, after):
        text = path.read_text()
        self.assertIn(before, text)
        path.write_text(text.replace(before, after, 1))

    def rejects(self, message):
        with self.assertRaisesRegex(CheckFailure, message):
            check_project(self.root)

    def test_valid_project(self):
        self.assertEqual(len(check_project(self.root)), 6)

    def test_missing_source(self):
        (self.root/'ios/StairClimb/Health/HealthStepReader.swift').unlink()
        self.rejects('Missing referenced file')

    def test_unlinked_source(self):
        (self.root/'ios/StairClimb/Core/Forgotten.swift').write_text('struct Forgotten {}')
        self.rejects('App source membership mismatch')

    def test_wrong_test_source_membership(self):
        project = openstep(self.project.read_text())
        objects = project['objects']
        target = next(o for o in objects.values() if o.get('name') == 'StairClimbTests' and o['isa'] == 'PBXNativeTarget')
        phase = next(objects[p] for p in target['buildPhases'] if objects[p]['isa'] == 'PBXSourcesBuildPhase')
        first, second = phase['files'][:2]
        self.replace(self.project, f'files = ( {first}, {second}', f'files = ( {second}')
        self.rejects('Test source membership mismatch')

    def test_wrong_scheme_target(self):
        path = self.root/'ios/StairClimb.xcodeproj/xcshareddata/xcschemes/StairClimb.xcscheme'
        self.replace(path, 'BlueprintIdentifier="', 'BlueprintIdentifier="BROKEN')
        self.rejects('Dangling project reference')

    def test_missing_entitlement(self):
        path = self.root/'ios/StairClimb/StairClimb.entitlements'
        path.write_bytes(plistlib.dumps({'com.apple.developer.healthkit': False}))
        self.rejects('Missing HealthKit entitlement')

    def test_release_ats_bypass(self):
        path = self.root/'ios/StairClimb/Info-Release.plist'
        data = plistlib.loads(path.read_bytes())
        data['NSAppTransportSecurity'] = {'NSAllowsArbitraryLoads': True}
        path.write_bytes(plistlib.dumps(data))
        self.rejects('Release has arbitrary ATS bypass')

    def test_release_local_exception_is_also_rejected(self):
        path = self.root/'ios/StairClimb/Info-Release.plist'
        data = plistlib.loads(path.read_bytes())
        data['NSAppTransportSecurity'] = {'NSAllowsLocalNetworking': True}
        path.write_bytes(plistlib.dumps(data))
        self.rejects('Release must use default HTTPS')

    def debug_ats(self):
        path = self.root/'ios/StairClimb/Info-Debug.plist'
        data = plistlib.loads(path.read_bytes())
        return path, data, data['NSAppTransportSecurity']

    def test_debug_local_ip_coverage_and_public_exclusion(self):
        _, _, ats = self.debug_ats()
        networks = [ipaddress.ip_network(address) for address in ats['NSExceptionDomains']]
        for value in ['127.0.0.1', '127.255.255.254', '10.0.0.1', '10.255.255.254',
                      '172.16.0.1', '172.31.255.254', '192.168.1.3', '192.168.255.254',
                      '::1', 'fc00::1', 'fdff::1', 'fe80::1', 'fe80:ffff::1']:
            address = ipaddress.ip_address(value)
            self.assertTrue(any(address in network for network in networks), value)
        for value in ['8.8.8.8', '1.1.1.1', '172.15.255.255', '172.32.0.1', '192.169.0.1',
                      '2001:4860:4860::8888', 'fc::1', 'fd::1', 'fe81::1', '::']:
            address = ipaddress.ip_address(value)
            self.assertFalse(any(address in network for network in networks), value)
        check_project(self.root)

    def test_debug_missing_each_ip_range_is_rejected(self):
        path, data, ats = self.debug_ats()
        exceptions = dict(ats['NSExceptionDomains'])
        for address in exceptions:
            with self.subTest(address=address):
                ats['NSExceptionDomains'] = {key: value for key, value in exceptions.items() if key != address}
                path.write_bytes(plistlib.dumps(data))
                self.rejects('Debug IP exceptions must cover exactly')

    def test_debug_legacy_local_key_alone_is_rejected(self):
        path, data, ats = self.debug_ats()
        del ats['NSExceptionDomains']
        path.write_bytes(plistlib.dumps(data))
        self.rejects('Debug ATS exception must be local only')

    def test_debug_public_or_wildcard_exceptions_are_rejected(self):
        path, data, ats = self.debug_ats()
        original = dict(ats['NSExceptionDomains'])
        for value in ['8.8.8.8', 'example.com', '0.0.0.0/0', '::/0', '*.local']:
            with self.subTest(value=value):
                ats['NSExceptionDomains'] = original | {value: {'NSExceptionAllowsInsecureHTTPLoads': True}}
                path.write_bytes(plistlib.dumps(data))
                self.rejects('Debug IP exceptions must cover exactly')

    def test_debug_missing_http_permission_or_extra_tls_relaxation_rejected(self):
        path, data, ats = self.debug_ats()
        for options in [{}, {'NSExceptionAllowsInsecureHTTPLoads': False},
                        {'NSExceptionAllowsInsecureHTTPLoads': True, 'NSIncludesSubdomains': True},
                        {'NSExceptionAllowsInsecureHTTPLoads': True, 'NSExceptionMinimumTLSVersion': 'TLSv1.0'}]:
            with self.subTest(options=options):
                ats['NSExceptionDomains']['192.168.0.0/16'] = options
                path.write_bytes(plistlib.dumps(data))
                self.rejects('Debug IP exception must allow only local HTTP')

    def test_debug_arbitrary_loads_are_still_rejected(self):
        path, data, ats = self.debug_ats()
        ats['NSAllowsArbitraryLoads'] = True
        path.write_bytes(plistlib.dumps(data))
        self.rejects('Debug has arbitrary ATS bypass')

    def test_release_cannot_inherit_debug_ip_exceptions(self):
        _, _, ats = self.debug_ats()
        path = self.root/'ios/StairClimb/Info-Release.plist'
        data = plistlib.loads(path.read_bytes())
        data['NSAppTransportSecurity'] = ats
        path.write_bytes(plistlib.dumps(data))
        self.rejects('Release must use default HTTPS')

    def test_wrong_configuration_association(self):
        path = self.root/'ios/Config/Debug.xcconfig'
        self.replace(path, 'Info-Debug.plist', 'Info-Release.plist')
        self.rejects('Debug Info.plist misassociated')

    def test_disabled_capability(self):
        self.replace(self.project, 'enabled = 1', 'enabled = 0')
        self.rejects('HealthKit capability not enabled')

    def test_test_target_has_no_app_dependency(self):
        parsed = openstep(self.project.read_text())
        dep_id = next(key for key, obj in parsed['objects'].items() if obj['isa'] == 'PBXTargetDependency')
        self.replace(self.project, f'dependencies = ( {dep_id} )', 'dependencies = ()')
        self.rejects('Tests do not depend on app')

    def test_wrong_bundle_loader(self):
        self.replace(self.project, 'BUNDLE_LOADER = "$(TEST_HOST)"', 'BUNDLE_LOADER = "wrong"')
        self.rejects('Wrong XCTest bundle loader')

    def test_missing_icon(self):
        (self.root/'ios/StairClimb/Assets.xcassets/AppIcon.appiconset/AppIcon.png').unlink()
        with self.assertRaises(FileNotFoundError):
            check_project(self.root)

    def test_rule_drift_from_backend(self):
        path = self.root/'ios/StairClimb/Core/StepRules.swift'
        self.replace(path, 'stepsPerFloor = 100', 'stepsPerFloor = 99')
        self.rejects('Client/server mismatch: STEPS_PER_FLOOR')

    def test_rule_drift_from_rust_service(self):
        self.replace(self.root/'backend/src/domain.rs', 'STEPS_PER_FLOOR: i64 = 100;', 'STEPS_PER_FLOOR: i64 = 99;')
        self.rejects('Rust/reference mismatch: STEPS_PER_FLOOR')

    def test_openstep_duplicate_key_rejected(self):
        with self.assertRaisesRegex(CheckFailure, 'Duplicate project key'):
            openstep('{ a = 1; a = 2; }')


if __name__ == '__main__':
    unittest.main()

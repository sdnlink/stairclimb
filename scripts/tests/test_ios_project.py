"""Regression tests prove the static check rejects real broken project wiring."""
from pathlib import Path
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

    def test_debug_local_http_and_all_exception_ranges_rejected(self):
        path = self.root/'ios/StairClimb/Info-Debug.plist'
        original = plistlib.loads(path.read_bytes())
        for value in ['127.0.0.0/8','10.0.0.0/8','172.16.0.0/12','192.168.0.0/16',
                      '::1','fc00::/7','fe80::/16','example.com','0.0.0.0/0','*.local']:
            with self.subTest(value=value):
                data = original | {'NSAppTransportSecurity': {'NSExceptionDomains': {
                    value: {'NSExceptionAllowsInsecureHTTPLoads': True}}}}
                path.write_bytes(plistlib.dumps(data))
                self.rejects('Debug must use default HTTPS')

    def test_debug_local_key_alone_rejected(self):
        path = self.root/'ios/StairClimb/Info-Debug.plist'
        data = plistlib.loads(path.read_bytes())
        data['NSAppTransportSecurity'] = {'NSAllowsLocalNetworking': True}
        path.write_bytes(plistlib.dumps(data))
        self.rejects('Debug must use default HTTPS')

    def test_debug_arbitrary_loads_are_still_rejected(self):
        path = self.root/'ios/StairClimb/Info-Debug.plist'
        data = plistlib.loads(path.read_bytes())
        data['NSAppTransportSecurity'] = {'NSAllowsArbitraryLoads': True}
        path.write_bytes(plistlib.dumps(data))
        self.rejects('Debug has arbitrary ATS bypass')

    def test_debug_legacy_exception_cannot_enter_release(self):
        path = self.root/'ios/StairClimb/Info-Release.plist'
        data = plistlib.loads(path.read_bytes())
        data['NSAppTransportSecurity'] = {'NSExceptionDomains': {'192.168.0.0/16': {
            'NSExceptionAllowsInsecureHTTPLoads': True}}}
        path.write_bytes(plistlib.dumps(data))
        self.rejects('Release must use default HTTPS')

    def test_http_address_bypass_rejected(self):
        self.replace(self.root/'ios/StairClimb/Network/ServiceAddress.swift',
                     'parts.scheme?.lowercased() == "https"', 'parts.scheme?.lowercased() == "http"')
        self.rejects('Client address policy must require HTTPS')

    def test_direct_client_bypass_rejected(self):
        self.replace(self.root/'ios/StairClimb/Network/APIClient.swift',
                     'try ServiceAddress.validated(baseURL.absoluteString)', 'baseURL')
        self.rejects('APIClient must revalidate HTTPS')

    def test_tls_minimum_cannot_be_lowered(self):
        self.replace(self.root/'ios/StairClimb/Network/APIClient.swift', '.TLSv12', '.TLSv10')
        self.rejects('URLSession must require at least TLS 1.2')

    def test_custom_certificate_trust_bypass_rejected(self):
        path = self.root/'ios/StairClimb/Network/APIClient.swift'
        path.write_text(path.read_text() + '\nlet credential = URLCredential(trust: serverTrust)\n')
        self.rejects('URLSession must preserve system certificate trust')

    def test_credential_redirects_cannot_be_enabled(self):
        self.replace(self.root/'ios/StairClimb/Network/APIClient.swift',
                     'completionHandler(nil)', 'completionHandler(request)')
        self.rejects('Credential redirects must remain disabled')

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

    def test_anonymous_registration_path_is_rejected(self):
        path = self.root/'ios/StairClimb/Network/SocialModel.swift'
        path.write_text(path.read_text() + '\nlet path = "/v1/users"\n')
        self.rejects('Obsolete anonymous registration')

    def test_persisting_password_is_rejected(self):
        path = self.root/'ios/StairClimb/Network/NetworkVault.swift'
        path.write_text(path.read_text() + '\nvar password: String?\n')
        self.rejects('must not enter persisted')

    def test_unwired_email_form_is_rejected(self):
        self.replace(self.root/'ios/StairClimb/Views/SocialView.swift',
                     'EmailAccountView(model: model)', 'Text("TODO")')
        self.rejects('Email forms must be connected')

    def test_unlinked_email_tests_are_rejected(self):
        (self.root/'ios/StairClimbTests/EmailAuthTests.swift').unlink()
        self.rejects('Missing referenced file')

    def test_secrets_surviving_background_is_rejected(self):
        self.replace(self.root/'ios/StairClimb/Views/EmailAccountView.swift',
                     'phase != .active { clearSecrets()', 'phase != .active { ignored(')
        self.rejects('Secrets must clear on close/background')

    def test_unwired_circle_tab_is_rejected(self):
        self.replace(self.root/'ios/StairClimb/Views/SocialView.swift',
                     'CircleView(model: social, local: local)', 'Text("TODO")')
        self.rejects('Circle page must be connected')

    def test_unwired_circle_pagination_is_rejected(self):
        self.replace(self.root/'ios/StairClimb/Views/CircleView.swift',
                     'model.refreshCircle(more: true)', 'model.refreshCircle()')
        self.rejects('Circle page action is not wired')

    def test_missing_circle_privacy_action_is_rejected(self):
        self.replace(self.root/'ios/StairClimb/Views/CircleView.swift',
                     'model.privacy(.revoke, confirmNewAttempt: true)', 'model.refreshCircle()')
        self.rejects('Circle page action is not wired')

    def test_missing_circle_midnight_test_is_rejected(self):
        self.replace(self.root/'ios/StairClimbTests/CircleTests.swift',
                     'func testMidnightInvalidatesHeldResponseAndForegroundReadsBeforeRegrouping(', 'func renamed(')
        self.rejects('Missing circle XCTest scenario')

    def test_openstep_duplicate_key_rejected(self):
        with self.assertRaisesRegex(CheckFailure, 'Duplicate project key'):
            openstep('{ a = 1; a = 2; }')

    def test_missing_success_time_or_cache_binding_is_rejected(self):
        for filename, binding in [
            ('ProgressViewScreen.swift', 'model.snapshotIsStale'),
            ('SocialView.swift', 'model.syncedAt'),
            ('SocialView.swift', 'model.syncIsStale'),
            ('SocialView.swift', 'model.boardUpdatedAt'),
            ('SocialView.swift', 'model.boardIsStale'),
            ('CircleView.swift', 'model.circleUpdatedAt'),
            ('CircleView.swift', 'model.circleIsStale'),
            ('CircleView.swift', 'model.circleNotice'),
        ]:
            with self.subTest(binding=binding):
                path = self.root/'ios/StairClimb/Views'/filename
                original = path.read_text()
                path.write_text(original.replace(binding, 'unboundValue'))
                self.rejects('Missing freshness display binding')
                path.write_text(original)

    def test_background_cache_marking_is_required(self):
        for filename, action in [('ProgressViewScreen.swift', 'else { model.markCached() }'),
                                 ('SocialView.swift', 'else { social.markCached() }')]:
            with self.subTest(filename=filename):
                path = self.root/'ios/StairClimb/Views'/filename
                original = path.read_text()
                path.write_text(original.replace(action, ''))
                self.rejects('Background must mark local and network caches')
                path.write_text(original)

    def test_missing_freshness_failure_path_test_is_rejected(self):
        path = self.root/'ios/StairClimbTests/NetworkTests.swift'
        self.replace(path, 'func testAcknowledgedSyncRemainsSuccessfulWhenBoardRefreshFails(', 'func removed(')
        self.rejects('Missing freshness XCTest scenario')


if __name__ == '__main__':
    unittest.main()

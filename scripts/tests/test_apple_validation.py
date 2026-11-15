"""Linux orchestration tests with fake tools; these NEVER compile Swift/run XCTest."""
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validate_apple import ROOT, ValidationFailure, failure_excerpt, select_device, validate


DEVICE = '12345678-1234-1234-1234-123456789ABC'
INVENTORY = {'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-18-2': [
    {'name': 'iPhone 16', 'udid': DEVICE, 'isAvailable': True, 'state': 'Shutdown'}]}}

# A subprocess fixture, not an alternative Apple toolchain. Failure switches verify
# the runner's behavior when actual commands fail or return unusable results.
FAKE_TOOL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
args = sys.argv[1:]
with open(os.environ['APPLE_FIXTURE_CALLS'], 'a') as calls:
    calls.write(json.dumps([Path(sys.argv[0]).name] + args) + '\n')
if Path(sys.argv[0]).name == 'xcodebuild':
    if args == ['-version']:
        print('Xcode ' + os.environ.get('APPLE_FIXTURE_VERSION', '16.2') + '\nBuild version FIXTURE')
    else:
        action = args[-1]
        config = args[args.index('-configuration') + 1]
        if os.environ.get('APPLE_FIXTURE_FAILURE') == action + '-' + config:
            if action == 'test' and os.environ.get('APPLE_FIXTURE_FAILED_BUNDLE'):
                Path(args[args.index('-resultBundlePath') + 1]).mkdir()
            print('IdentityVaultTests.swift:72: error: XCTAssertNil failed: Failure(status: -34018)')
            print('intentional fake tool failure')
            sys.exit(65)
        if action == 'test':
            Path(args[args.index('-resultBundlePath') + 1]).mkdir()
            if os.environ.get('APPLE_FIXTURE_MUTATE'):
                with open('ios/StairClimb/Core/StepRules.swift', 'a') as source:
                    source.write('\n// fixture source change\n')
        print('fixture command completed; no Swift or XCTest executed')
elif args[:2] == ['simctl', 'list']:
    print(os.environ['APPLE_FIXTURE_INVENTORY'])
elif args[:4] == ['xcresulttool', 'get', 'test-results', 'summary']:
    if os.environ.get('APPLE_FIXTURE_SUMMARY_ERROR'):
        print('Could not read test results')
        sys.exit(1)
    print(os.environ.get('APPLE_FIXTURE_SUMMARY', json.dumps({
        'totalTestCount': 91, 'passedTests': 91, 'failedTests': 0, 'skippedTests': 0})))
else:
    sys.exit(64)
'''


class AppleValidationTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)/'project with spaces'
        self.root.mkdir()
        shutil.copytree(ROOT/'ios', self.root/'ios')
        for relative in ['backend/domain.py', 'backend/src/domain.rs',
                         'scripts/check_ios_project.py', 'scripts/validate_apple.py',
                         '.github/workflows/apple.yml']:
            destination = self.root/relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT/relative, destination)
        self.output = self.root/'.runtime/results'
        self.bin = Path(temp.name)/'fixture-bin'
        self.bin.mkdir()
        for name in ['xcrun', 'xcodebuild']:
            tool = self.bin/name
            tool.write_text(FAKE_TOOL)
            tool.chmod(0o755)
        self.calls = Path(temp.name)/'calls.jsonl'
        self.env = patch.dict(os.environ, {
            'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
            'APPLE_FIXTURE_CALLS': str(self.calls),
            'APPLE_FIXTURE_INVENTORY': json.dumps(INVENTORY),
        })
        self.env.start()
        self.addCleanup(self.env.stop)

    def run_fixture(self, requested=None):
        with patch('validate_apple.platform.system', return_value='Darwin'), redirect_stdout(io.StringIO()):
            return validate(self.root, self.output, requested)

    def receipt(self):
        return json.loads((self.output/'receipt.json').read_text())

    def commands(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_complete_runner_keeps_real_project_full_suite_and_artifacts(self):
        receipt = self.run_fixture()
        self.assertEqual(receipt['status'], 'passed')
        self.assertEqual(receipt['tests']['passedTests'], 91)  # fixture count, NOT an Apple result
        self.assertTrue(all(entry['exit_status'] == 0 for entry in receipt['commands']))
        self.assertTrue((self.output/'Tests.xcresult').is_dir())
        commands = self.commands()
        builds = [args for args in commands if args[-1] == 'build']
        self.assertEqual([args[args.index('-configuration')+1] for args in builds], ['Debug', 'Release'])
        test = next(args for args in commands if args[-1] == 'test')
        self.assertIn(f'platform=iOS Simulator,id={DEVICE}', test)
        for args in builds + [test]:
            self.assertIn(str(self.root/'ios/StairClimb.xcodeproj'), args)
            self.assertEqual(args[args.index('-scheme')+1], 'StairClimb')
            self.assertIn('CODE_SIGNING_ALLOWED=YES', args)
            self.assertIn('CODE_SIGN_IDENTITY=-', args)
            self.assertIn('AD_HOC_CODE_SIGNING_ALLOWED=YES', args)
            self.assertNotIn('CODE_SIGNING_ALLOWED=NO', args)
            self.assertFalse(any(arg.startswith(('DEVELOPMENT_TEAM=', 'PROVISIONING_PROFILE_SPECIFIER=')) for arg in args))
            self.assertFalse(any(arg.startswith(('-only-testing', '-skip-testing')) for arg in args))
        self.assertIn('ios/StairClimb/StairClimb.entitlements', receipt['source']['sha256'])
        self.assertIn('ios/StairClimbTests/EmailAuthTests.swift', receipt['source']['sha256'])

    def test_build_failure_stops_before_tests_and_preserves_exit_code(self):
        with patch.dict(os.environ, {'APPLE_FIXTURE_FAILURE': 'build-Release'}):
            with self.assertRaisesRegex(ValidationFailure, 'exit 65'):
                self.run_fixture()
        receipt = self.receipt()
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual(receipt['commands'][-1]['exit_status'], 65)
        self.assertFalse(any(args[-1] == 'test' for args in self.commands()))

    def test_failed_xctest_cannot_report_passed(self):
        with patch.dict(os.environ, {'APPLE_FIXTURE_FAILURE': 'test-Debug'}):
            with self.assertRaisesRegex(ValidationFailure, 'xctest failed'):
                self.run_fixture()
        self.assertEqual(self.receipt()['status'], 'failed')
        self.assertFalse(any('xcresulttool' in args for args in self.commands()))

    def test_failed_assertion_is_visible_in_console(self):
        console = io.StringIO()
        with patch.dict(os.environ, {'APPLE_FIXTURE_FAILURE': 'test-Debug'}), \
                patch('validate_apple.platform.system', return_value='Darwin'), redirect_stdout(console):
            with self.assertRaisesRegex(ValidationFailure, 'xctest failed'):
                validate(self.root, self.output)
        self.assertIn('XCTAssertNil failed', console.getvalue())
        self.assertIn('-34018', console.getvalue())
        self.assertEqual(self.receipt()['commands'][-1]['exit_status'], 65)

    def test_failed_bundle_still_collects_counts_without_masking_xcode_failure(self):
        summary = {'totalTestCount': 99, 'passedTests': 98, 'failedTests': 1, 'skippedTests': 0,
                   'testFailures': [{'testName': 'testActualKeychainInsertUpdateAndRead',
                                     'failureText': 'Missing entitlement -34018'}]}
        with patch.dict(os.environ, {'APPLE_FIXTURE_FAILURE': 'test-Debug',
                                    'APPLE_FIXTURE_FAILED_BUNDLE': '1',
                                    'APPLE_FIXTURE_SUMMARY': json.dumps(summary)}):
            with self.assertRaisesRegex(ValidationFailure, 'xctest failed with exit 65'):
                self.run_fixture()
        receipt = self.receipt()
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual(receipt['tests']['failedTests'], 1)
        self.assertEqual(receipt['test_failures'], summary['testFailures'])
        self.assertTrue((self.output/'test-summary.log').is_file())

    def test_unreadable_failed_bundle_keeps_original_exit_65(self):
        with patch.dict(os.environ, {'APPLE_FIXTURE_FAILURE': 'test-Debug',
                                    'APPLE_FIXTURE_FAILED_BUNDLE': '1',
                                    'APPLE_FIXTURE_SUMMARY_ERROR': '1'}):
            with self.assertRaisesRegex(ValidationFailure, 'xctest failed with exit 65'):
                self.run_fixture()
        self.assertIn('test-summary failed', self.receipt()['diagnostic_error'])
        self.assertEqual(self.receipt()['status'], 'failed')

    def test_failure_excerpt_surfaces_assertion_before_long_tail_and_is_bounded(self):
        text = '\n'.join(['build output'] * 120 + ['File.swift:7: error: XCTAssertNil failed -34018']
                         + ['more output'] * 200)
        excerpt = failure_excerpt(text)
        self.assertIn('XCTAssertNil failed -34018', excerpt)
        self.assertLessEqual(len(excerpt.splitlines()), 90)

    def test_no_available_simulator_fails_before_build(self):
        with patch.dict(os.environ, {'APPLE_FIXTURE_INVENTORY': '{"devices": {}}'}):
            with self.assertRaisesRegex(ValidationFailure, 'No matching available iPhone'):
                self.run_fixture()
        self.assertEqual(self.receipt()['status'], 'failed')
        self.assertFalse(any(args[-1] in ['build', 'test'] for args in self.commands()))

    def test_wrong_requested_device_does_not_silently_fall_back(self):
        with self.assertRaisesRegex(ValidationFailure, 'No matching available iPhone'):
            self.run_fixture('87654321-4321-4321-4321-CBA987654321')
        self.assertEqual(self.receipt()['status'], 'failed')

    def test_old_xcode_fails_with_receipt(self):
        with patch.dict(os.environ, {'APPLE_FIXTURE_VERSION': '15.4'}):
            with self.assertRaisesRegex(ValidationFailure, 'Xcode 16'):
                self.run_fixture()
        self.assertEqual(self.receipt()['status'], 'failed')
        self.assertEqual(len(self.commands()), 1)

    def test_zero_skipped_failed_or_malformed_results_cannot_pass(self):
        for summary in [
            {'totalTestCount': 0, 'passedTests': 0, 'failedTests': 0, 'skippedTests': 0},
            {'totalTestCount': 2, 'passedTests': 1, 'failedTests': 0, 'skippedTests': 1},
            {'totalTestCount': 2, 'passedTests': 1, 'failedTests': 1, 'skippedTests': 0},
            {'totalTestCount': 2, 'passedTests': 1, 'failedTests': 0, 'skippedTests': 0},
            {},
        ]:
            with self.subTest(summary=summary):
                self.output = self.root/'.runtime'/str(len(list((self.root/'.runtime').glob('*'))))
                with patch.dict(os.environ, {'APPLE_FIXTURE_SUMMARY': json.dumps(summary)}):
                    with self.assertRaisesRegex(ValidationFailure, 'XCTest summary'):
                        self.run_fixture()
                self.assertEqual(self.receipt()['status'], 'failed')

    def test_reused_output_directory_is_not_overwritten(self):
        self.output.mkdir(parents=True)
        (self.output/'receipt.json').write_text('previous evidence')
        with self.assertRaises(FileExistsError):
            self.run_fixture()
        self.assertEqual((self.output/'receipt.json').read_text(), 'previous evidence')
        self.assertFalse(self.calls.exists())

    def test_changed_source_cannot_receive_a_passed_receipt(self):
        with patch.dict(os.environ, {'APPLE_FIXTURE_MUTATE': 'yes'}):
            with self.assertRaisesRegex(ValidationFailure, 'inputs changed'):
                self.run_fixture()
        self.assertEqual(self.receipt()['status'], 'failed')

    def test_artifacts_cannot_be_written_over_source(self):
        self.output = self.root/'ios/artifacts'
        with self.assertRaisesRegex(ValidationFailure, 'outside source'):
            self.run_fixture()
        self.assertFalse(self.output.exists())

    def test_broken_security_configuration_stops_before_apple_commands(self):
        (self.root/'ios/StairClimb/StairClimb.entitlements').unlink()
        with self.assertRaisesRegex(ValidationFailure, 'structure failed'):
            self.run_fixture()
        self.assertEqual(self.receipt()['status'], 'failed')
        self.assertFalse(self.calls.exists())

    def test_non_mac_guard_never_runs_fake_apple_tools(self):
        with patch('validate_apple.platform.system', return_value='Linux'):
            with self.assertRaisesRegex(ValidationFailure, 'requires macOS'):
                validate(self.root, self.output)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.calls.exists())

    def test_cli_on_linux_fails_without_claiming_an_apple_result(self):
        if sys.platform != 'linux':
            return  # This platform-specific guard is exercised by the Linux regression run.
        result = subprocess.run([sys.executable, str(ROOT/'scripts/validate_apple.py'),
                                 '--output', str(self.output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('requires macOS', result.stderr)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.calls.exists())

    def test_simulator_selection_excludes_wrong_platform_old_and_unavailable(self):
        inventory = json.loads(json.dumps(INVENTORY))
        inventory['devices'].update({
            'com.apple.CoreSimulator.SimRuntime.iOS-16-4': [
                {'name': 'iPhone 14', 'udid': DEVICE, 'isAvailable': True}],
            'com.apple.CoreSimulator.SimRuntime.tvOS-26-0': [
                {'name': 'iPhone wrong platform', 'udid': DEVICE, 'isAvailable': True}],
            'com.apple.CoreSimulator.SimRuntime.iOS-26-0': [
                {'name': 'iPhone unavailable', 'udid': DEVICE, 'isAvailable': False},
                {'name': 'iPad', 'udid': DEVICE, 'isAvailable': True}],
        })
        self.assertEqual(select_device(inventory)['runtime'], 'com.apple.CoreSimulator.SimRuntime.iOS-18-2')


if __name__ == '__main__':
    unittest.main()

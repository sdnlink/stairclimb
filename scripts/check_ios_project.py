#!/usr/bin/env python3
"""Dependency-free Xcode graph/config check. This is NOT a Swift compiler."""
import argparse
import ast
import json
from pathlib import Path
import plistlib
import re
import struct
import xml.etree.ElementTree as ET


class CheckFailure(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise CheckFailure(message)


def openstep(text):
    """Parse dictionaries/lists rather than treating a reference substring as a link."""
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S)
    pattern = re.compile(r'"(?:\\.|[^"\\])*"|[{}()=;,]|[A-Za-z0-9_./$<>:+-]+')
    tokens = []
    last = 0
    for match in pattern.finditer(text):
        require(not text[last:match.start()].strip(), 'Unrecognized project syntax')
        tokens.append(match.group())
        last = match.end()
    require(not text[last:].strip(), 'Unrecognized project suffix')
    index = 0

    def take(expected=None):
        nonlocal index
        require(index < len(tokens), 'Unexpected end of project')
        value = tokens[index]
        index += 1
        require(expected is None or value == expected, f'Expected {expected}, got {value}')
        return value

    def value():
        token = take()
        if token == '{':
            result = {}
            while tokens[index] != '}':
                key = take()
                if key.startswith('"'):
                    key = json.loads(key)
                require(key not in result, f'Duplicate project key: {key}')
                take('=')
                result[key] = value()
                take(';')
            take('}')
            return result
        if token == '(':
            result = []
            while tokens[index] != ')':
                result.append(value())
                if tokens[index] != ')':
                    take(',')
            take(')')
            return result
        require(token not in '}=;,)', 'Unexpected project token')
        return json.loads(token) if token.startswith('"') else token

    try:
        result = value()
        require(index == len(tokens), 'Trailing project content')
        return result
    except (IndexError, json.JSONDecodeError) as exc:
        raise CheckFailure('Malformed OpenStep project') from exc


def xcconfig(path, seen=None):
    seen = set() if seen is None else set(seen)
    require(path not in seen, f'Configuration include cycle: {path}')
    require(path.is_file(), f'Missing configuration: {path}')
    seen.add(path)
    result = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('//'):
            continue
        include = re.fullmatch(r'#include "([^"]+)"', line)
        if include:
            result.update(xcconfig(path.parent / include[1], seen))
        else:
            setting = re.fullmatch(r'([A-Z_]+)\s*=\s*(.+)', line)
            require(setting is not None, f'Invalid configuration line in {path}: {line}')
            result[setting[1]] = setting[2]
    return result


def check_project(root):
    root = Path(root).resolve()
    ios = root / 'ios'
    project_path = ios / 'StairClimb.xcodeproj/project.pbxproj'
    require(project_path.is_file(), 'Missing Xcode project')
    project = openstep(project_path.read_text())
    objects = project['objects']

    def obj(oid, isa=None):
        require(oid in objects, f'Dangling project reference: {oid}')
        result = objects[oid]
        require(isa is None or result['isa'] == isa, f'Wrong reference type for {oid}: expected {isa}')
        return result

    main = obj(project['rootObject'], 'PBXProject')
    resolved = {}
    visited = set()

    def visit(oid, parent):
        require(oid not in visited, f'Duplicate/cyclic group reference: {oid}')
        visited.add(oid)
        node = obj(oid)
        if node['isa'] == 'PBXGroup':
            require(node.get('sourceTree') == '<group>', 'Unsupported group source tree')
            folder = parent / node.get('path', '')
            for child in node['children']:
                visit(child, folder)
        else:
            require(node['isa'] == 'PBXFileReference', 'Non-file in group')
            if node['sourceTree'] == '<group>':
                path = (parent / node['path']).resolve()
                require(path.is_relative_to(ios), f'File outside iOS directory: {path}')
                require(path.exists(), f'Missing referenced file: {path}')
                resolved[oid] = path
            else:
                require(node['sourceTree'] in ['SDKROOT', 'BUILT_PRODUCTS_DIR'], 'Unknown file source tree')

    visit(main['mainGroup'], ios)
    targets = {obj(t, 'PBXNativeTarget')['name']: (t, obj(t)) for t in main['targets']}
    require(set(targets) == {'StairClimb', 'StairClimbTests'}, 'Missing application or actual XCTest target')
    app_id, app = targets['StairClimb']
    test_id, tests = targets['StairClimbTests']
    require(app['productType'] == 'com.apple.product-type.application', 'Wrong app product type')
    require(tests['productType'] == 'com.apple.product-type.bundle.unit-test', 'Wrong XCTest product type')

    def phase_files(target, isa):
        phases = [obj(p) for p in target['buildPhases'] if obj(p)['isa'] == isa]
        require(len(phases) == 1, f'Expected one {isa}')
        ids = [obj(b, 'PBXBuildFile')['fileRef'] for b in phases[0]['files']]
        require(len(ids) == len(set(ids)), f'Duplicate file in {isa}')
        return ids

    app_sources = {resolved.get(f) for f in phase_files(app, 'PBXSourcesBuildPhase')}
    test_sources = {resolved.get(f) for f in phase_files(tests, 'PBXSourcesBuildPhase')}
    require(app_sources and app_sources == set((ios/'StairClimb').rglob('*.swift')), 'App source membership mismatch')
    require(test_sources and test_sources == set((ios/'StairClimbTests').rglob('*.swift')), 'Test source membership mismatch')
    require(all('@testable import StairClimb' in p.read_text() for p in test_sources), 'Tests not linked to app module')
    dependency_targets = [obj(d, 'PBXTargetDependency')['target'] for d in tests['dependencies']]
    require(app_id in dependency_targets, 'Tests do not depend on app')
    for dependency in tests['dependencies']:
        dep = obj(dependency)
        proxy = obj(dep['targetProxy'], 'PBXContainerItemProxy')
        require(proxy['remoteGlobalIDString'] == dep['target'] and proxy['containerPortal'] == project['rootObject'], 'Invalid test dependency proxy')

    capabilities = main['attributes']['TargetAttributes'][app_id]['SystemCapabilities']
    require(capabilities['com.apple.HealthKit']['enabled'] == '1', 'HealthKit capability not enabled')
    frameworks = [obj(obj(b, 'PBXBuildFile')['fileRef'])['path']
                  for phase in app['buildPhases'] if obj(phase)['isa'] == 'PBXFrameworksBuildPhase'
                  for b in obj(phase)['files']]
    for name in ['HealthKit', 'Security']:
        require(f'System/Library/Frameworks/{name}.framework' in frameworks, f'Missing {name} link')

    def configurations(target):
        return {obj(c, 'XCBuildConfiguration')['name']: obj(c)
                for c in obj(target['buildConfigurationList'], 'XCConfigurationList')['buildConfigurations']}

    app_configs = configurations(app)
    require(set(app_configs) == {'Debug', 'Release'}, 'Missing Debug/Release configuration')
    for mode, config in app_configs.items():
        require(config.get('baseConfigurationReference') in resolved, f'{mode} base config not referenced')
        settings = xcconfig(resolved[config['baseConfigurationReference']]) | config['buildSettings']
        require(settings.get('IPHONEOS_DEPLOYMENT_TARGET') == '17.0', 'Unexpected deployment target')
        require(settings.get('SWIFT_VERSION') == '5.0', 'Unexpected Swift language setting')
        require(settings.get('INFOPLIST_FILE') == f'StairClimb/Info-{mode}.plist', f'{mode} Info.plist misassociated')
        require(settings.get('CODE_SIGN_ENTITLEMENTS') == 'StairClimb/StairClimb.entitlements', 'Entitlement misassociated')
        entitlement = plistlib.loads((ios/settings['CODE_SIGN_ENTITLEMENTS']).read_bytes())
        require(entitlement.get('com.apple.developer.healthkit') is True, 'Missing HealthKit entitlement')
        info = plistlib.loads((ios/settings['INFOPLIST_FILE']).read_bytes())
        require(info.get('CFBundleDisplayName') == '爬楼梯', 'Missing Chinese app name')
        for key in ['NSHealthShareUsageDescription', 'NSHealthUpdateUsageDescription']:
            require(re.search('[\u4e00-\u9fff]', info.get(key, '')), f'Missing Chinese {key}')
        require(not any('Location' in key for key in info), 'Unrequested location capability')
        ats = info.get('NSAppTransportSecurity', {})
        require(not ats.get('NSAllowsArbitraryLoads') and not ats.get('NSAllowsArbitraryLoadsInWebContent'), f'{mode} has arbitrary ATS bypass')
        require(not ats, f'{mode} must use default HTTPS transport security')
        if mode == 'Debug':
            require(settings.get('ENABLE_TESTABILITY') == 'YES', 'Debug not testable')
    address = (ios/'StairClimb/Network/ServiceAddress.swift').read_text()
    api = (ios/'StairClimb/Network/APIClient.swift').read_text()
    require('parts.scheme?.lowercased() == "https"' in address and 'allowLocalHTTP' not in address
            and 'scheme == "http"' not in address, 'Client address policy must require HTTPS in all builds')
    require('try ServiceAddress.validated(baseURL.absoluteString)' in api,
            'APIClient must revalidate HTTPS before sending')
    require('configuration.tlsMinimumSupportedProtocolVersion = .TLSv12' in api,
            'URLSession must require at least TLS 1.2')
    require(not re.search(r'serverTrust|SecTrust|URLCredential\s*\(\s*trust:|didReceive\s+challenge', api),
            'URLSession must preserve system certificate trust')
    require('completionHandler(nil)' in api, 'Credential redirects must remain disabled')
    auth = (ios/'StairClimb/Network/EmailAuth.swift').read_text()
    social = (ios/'StairClimb/Network/SocialModel.swift').read_text()
    account_view = (ios/'StairClimb/Views/EmailAccountView.swift').read_text()
    social_view = (ios/'StairClimb/Views/SocialView.swift').read_text()
    vault = (ios/'StairClimb/Network/NetworkVault.swift').read_text()
    require('/v1/users' not in social and 'model.register(' not in social_view,
            'Obsolete anonymous registration must not be a client path')
    for action in ['login', 'register', 'verify', 'resend', 'forgot-password', 'reset-password', 'bind', 'register-independent']:
        require(re.search(r'\b' + re.escape(action) + r'\b', auth), f'Missing email action: {action}')
    require('EmailAccountView(model: model)' in social_view and 'model.emailAction(' in account_view,
            'Email forms must be connected to actual social model')
    require('SecureField(' in account_view and '.onDisappear { clearSecrets()' in account_view
            and 'phase != .active { clearSecrets()' in account_view, 'Secrets must clear on close/background')
    require(not re.search(r'\b(?:email|password|proof)\s*:', vault),
            'Email/password/mail proof must not enter persisted network state')
    require('var refreshToken: String?' in vault and 'var accessExpiresAt: Date?' in vault,
            'Persistent session must include refresh and expiry')
    require('state.identity?.refreshUncertain = true' in social and 'state.logoutPending = true' in social,
            'Refresh uncertainty and pending logout barriers must persist')
    require(not re.search(r'\b(?:print|debugPrint|NSLog|Logger)\s*\(', auth + social + account_view + api),
            'Auth/network sources must not log private fields')
    for config in configurations(tests).values():
        settings = config['buildSettings']
        require(settings.get('TEST_HOST') == '$(BUILT_PRODUCTS_DIR)/StairClimb.app/StairClimb', 'Wrong XCTest host')
        require(settings.get('BUNDLE_LOADER') == '$(TEST_HOST)', 'Wrong XCTest bundle loader')

    scheme = ET.parse(ios/'StairClimb.xcodeproj/xcshareddata/xcschemes/StairClimb.xcscheme').getroot()
    for reference in scheme.iter('BuildableReference'):
        target_id = reference.attrib['BlueprintIdentifier']
        target = obj(target_id, 'PBXNativeTarget')
        require(reference.attrib['ReferencedContainer'] == 'container:StairClimb.xcodeproj', 'Wrong scheme container')
        require(reference.attrib['BlueprintName'] == target['name'], 'Wrong scheme blueprint name')
        require(reference.attrib['BuildableName'] == obj(target['productReference'])['path'], 'Wrong scheme product')
    testables = scheme.findall('./TestAction/Testables/TestableReference')
    require(len(testables) == 1 and testables[0].attrib.get('skipped') == 'NO', 'Scheme skips unit tests')
    require(testables[0].find('BuildableReference').attrib['BlueprintIdentifier'] == test_id, 'Scheme not testing actual test target')
    require(scheme.find('TestAction').attrib['buildConfiguration'] == 'Debug', 'Wrong scheme test configuration')
    buildables = scheme.findall('./BuildAction/BuildActionEntries/BuildActionEntry')
    require(any(e.attrib.get('buildForTesting') == 'YES' and e.find('BuildableReference').attrib['BlueprintIdentifier'] == app_id for e in buildables), 'Scheme does not build app for testing')

    resource_ids = phase_files(app, 'PBXResourcesBuildPhase')
    assets = ios/'StairClimb/Assets.xcassets'
    require(assets in [resolved.get(r) for r in resource_ids], 'Assets not in resources phase')
    catalog = json.loads((assets/'AppIcon.appiconset/Contents.json').read_text())
    require(len(catalog['images']) > 0, 'Missing app icon')
    for item in catalog['images']:
        png = (assets/'AppIcon.appiconset'/item['filename']).read_bytes()
        require(png[:8] == b'\x89PNG\r\n\x1a\n' and struct.unpack('>II', png[16:24]) == (1024, 1024), 'Invalid app icon dimensions')

    backend = ast.parse((root/'backend/domain.py').read_text())
    constants = {n.targets[0].id: ast.literal_eval(n.value) for n in backend.body
                 if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and isinstance(n.value, ast.Constant)}
    rust = (root/'backend/src/domain.rs').read_text()
    swift = (ios/'StairClimb/Core/StepRules.swift').read_text()
    for server, client in [('STEPS_PER_FLOOR', 'stepsPerFloor'), ('MAX_STEPS', 'maximumSteps'), ('CIRCLE_BAND_STEPS', 'circleBandSteps')]:
        rust_value = re.search(rf'pub const {server}: i64 = ([0-9_]+);', rust)
        require(rust_value and int(rust_value[1].replace('_', '')) == constants[server], f'Rust/reference mismatch: {server}')
        match = re.search(rf'static let {client} = ([0-9_]+)', swift)
        require(match and int(match[1].replace('_', '')) == constants[server], f'Client/server mismatch: {server}')
    require('Asia/Shanghai' in (ios/'StairClimb/Core/ShanghaiDay.swift').read_text(), 'Missing shared day timezone')
    require('chrono_tz::Asia::Shanghai' in rust, 'Missing Rust Shanghai timezone')
    return [f'PASS project reference graph: {len(objects)} objects; {len(app_sources)} app + {len(test_sources)} XCTest sources',
            'PASS shared scheme, XCTest host/dependency, source/resource membership, icon',
            'PASS HealthKit capability/entitlements, Chinese privacy strings, no location permission',
            'PASS strict HTTPS in Debug/Release, no ATS exceptions, system trust, TLS 1.2, redirects disabled; email forms/session/privacy wiring',
            'PASS client/backend constants: 100 steps/floor, max 1000000, circle band 1000; Shanghai zone',
            'LIMIT: static structure only; no Swift compile, XCTest execution, signing, HealthKit or visual validation']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        print('\n'.join(check_project(args.root)))
    except (CheckFailure, KeyError, OSError, ET.ParseError, plistlib.InvalidFileException) as exc:
        parser.exit(1, f'FAIL: {exc}\n')


if __name__ == '__main__':
    main()

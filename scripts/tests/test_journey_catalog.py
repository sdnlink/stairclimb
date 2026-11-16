"""Exercise the delivered catalog and real Xcode graph in isolated projects."""
import copy
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_ios_project import CheckFailure, check_project, openstep


SOURCE = Path(__file__).resolve().parents[2]
CATALOG = Path('ios/StairClimb/Resources/ClimbJourneys.json')


class JourneyCatalogChecks(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        shutil.copytree(SOURCE/'ios', self.root/'ios')
        (self.root/'backend/src').mkdir(parents=True)
        for relative in ['backend/domain.py', 'backend/src/domain.rs']:
            shutil.copyfile(SOURCE/relative, self.root/relative)
        self.path = self.root/CATALOG
        self.data = json.loads(self.path.read_text(encoding='utf-8'))
        self.project = self.root/'ios/StairClimb.xcodeproj/project.pbxproj'

    def write(self, data):
        self.path.write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')

    def rejects(self, *locations):
        with self.assertRaises(CheckFailure) as caught:
            check_project(self.root)
        message = str(caught.exception)
        self.assertIn('ClimbJourneys.json', message)
        for location in locations:
            self.assertIn(str(location), message)

    def graph(self):
        return openstep(self.project.read_text())

    def save_graph(self, graph):
        # The parser accepts JSON-quoted OpenStep atoms. Mutate parsed links,
        # without relying on PBX identifiers or incidental project comments.
        def encode(value):
            if isinstance(value, dict):
                return '{ ' + ' '.join(f'{encode(k)} = {encode(v)};' for k, v in value.items()) + ' }'
            if isinstance(value, list):
                return '( ' + ', '.join(map(encode, value)) + ' )'
            return json.dumps(value)
        self.project.write_text(encode(graph))

    def resource_phase(self, graph, target_name):
        objects = graph['objects']
        target = next(o for o in objects.values()
                      if o['isa'] == 'PBXNativeTarget' and o['name'] == target_name)
        return next(objects[p] for p in target['buildPhases']
                    if objects[p]['isa'] == 'PBXResourcesBuildPhase')

    def journey_links(self, graph):
        objects = graph['objects']
        reference = next(key for key, value in objects.items()
                         if value['isa'] == 'PBXFileReference' and value.get('path') == 'ClimbJourneys.json')
        build = next(key for key, value in objects.items()
                     if value['isa'] == 'PBXBuildFile' and value.get('fileRef') == reference)
        return reference, build

    def test_valid_project(self):
        self.assertGreaterEqual(len(self.data['routes']), 2)
        self.assertTrue(all(len(route['nodes']) >= 3 for route in self.data['routes']))
        self.assertEqual(len(check_project(self.root)), 6)
        self.assertEqual(len(check_project(SOURCE)), 6)

    def test_complete_v3_contract_accepts_legal_ids_and_cross_route_node_reuse(self):
        for route in self.data['routes']:
            self.assertIsInstance(route['completionText'], str)
            self.assertTrue(route['completionText'].strip())
        self.data['routes'][0]['id'] = 'A_1.2'
        self.data['routes'][1]['id'] = '0'
        for route in self.data['routes']:
            route['nodes'][0]['id'] = 'N_1.2'
        self.write(self.data)
        self.assertEqual(len(check_project(self.root)), 6)

    def test_route_completion_copy_is_required_nonblank_text(self):
        for route_index in range(len(self.data['routes'])):
            for value in [None, False, 3, [], {}, '', ' \n\t']:
                with self.subTest(route=route_index, value=value):
                    data = copy.deepcopy(self.data)
                    route = data['routes'][route_index]
                    route['completionText'] = value
                    self.write(data)
                    self.rejects(route['id'], 'completionText')
            data = copy.deepcopy(self.data)
            route = data['routes'][route_index]
            del route['completionText']
            self.write(data)
            self.rejects(route['id'], 'completionText')

    def test_rejects_empty_node_story(self):
        self.data['routes'][0]['nodes'][0]['story'] = '   '
        self.write(self.data)
        self.rejects('rain-post-office', 'rain-post-office-eaves', 'story')

    def test_malformed_json_reports_file_and_position(self):
        self.path.write_text('{"schemaVersion": 1, "routes": [}', encoding='utf-8')
        self.rejects('line 1', 'column')

    def test_invalid_utf8_reports_file(self):
        self.path.write_bytes(b'\xff')
        self.rejects('UTF-8')

    def test_invalid_root_structures(self):
        for value in [None, [], True, 1, 'routes']:
            with self.subTest(root=value):
                self.write(value)
                self.rejects('root')

    def test_version_is_required_and_exact_integer_one(self):
        for value in [None, True, False, 1.0, '1', 0, -1, 2]:
            with self.subTest(version=value):
                self.write(self.data | {'schemaVersion': value})
                self.rejects('schemaVersion')
        data = copy.deepcopy(self.data)
        del data['schemaVersion']
        self.write(data)
        self.rejects('schemaVersion')

    def test_routes_are_required_array_with_at_least_two_items(self):
        for value in [None, {}, 'routes', [], self.data['routes'][:1]]:
            with self.subTest(routes=value):
                self.write(self.data | {'routes': value})
                self.rejects('routes')
        self.write({'schemaVersion': 1})
        self.rejects('routes')

    def test_route_must_be_object(self):
        for value in [None, [], 1, 'route']:
            with self.subTest(route=value):
                data = copy.deepcopy(self.data)
                data['routes'][0] = value
                self.write(data)
                self.rejects('routes[0]')

    def test_route_copy_is_required_nonblank_text(self):
        for field in ['title', 'summary']:
            for value in [None, False, 3, [], {}, '', ' \n\t']:
                with self.subTest(field=field, value=value):
                    data = copy.deepcopy(self.data)
                    data['routes'][0][field] = value
                    self.write(data)
                    self.rejects('rain-post-office', field)
            data = copy.deepcopy(self.data)
            del data['routes'][0][field]
            self.write(data)
            self.rejects('rain-post-office', field)

    def test_nodes_are_required_array_with_at_least_three_items(self):
        for value in [None, {}, 'nodes', [], self.data['routes'][0]['nodes'][:2]]:
            with self.subTest(nodes=value):
                data = copy.deepcopy(self.data)
                data['routes'][0]['nodes'] = value
                self.write(data)
                self.rejects('rain-post-office', 'nodes')
        del self.data['routes'][0]['nodes']
        self.write(self.data)
        self.rejects('rain-post-office', 'nodes')

    def test_node_must_be_object(self):
        for value in [None, [], 1, 'node']:
            with self.subTest(node=value):
                data = copy.deepcopy(self.data)
                data['routes'][0]['nodes'][0] = value
                self.write(data)
                self.rejects('rain-post-office', 'nodes[0]')

    def test_node_copy_is_required_nonblank_text(self):
        for field in ['title', 'story', 'completionText']:
            for value in [None, False, 3, [], {}, '', ' \n\t']:
                with self.subTest(field=field, value=value):
                    data = copy.deepcopy(self.data)
                    data['routes'][0]['nodes'][0][field] = value
                    self.write(data)
                    self.rejects('rain-post-office', 'rain-post-office-eaves', field)
            data = copy.deepcopy(self.data)
            del data['routes'][0]['nodes'][0][field]
            self.write(data)
            self.rejects('rain-post-office', 'rain-post-office-eaves', field)

    def test_ids_are_required_ascii_identifiers_with_alphanumeric_first_character(self):
        for kind in ['route', 'node']:
            for value in [None, 1, True, [], {}, '', ' ', '中文', 'bad/id',
                          'bad id', '-start', '_start', '.start', 'a'*65, 'a\n', 'a\t']:
                with self.subTest(kind=kind, value=value):
                    data = copy.deepcopy(self.data)
                    route = data['routes'][0]
                    item = route if kind == 'route' else route['nodes'][0]
                    item['id'] = value
                    self.write(data)
                    self.rejects('routes[0]', 'id')
            data = copy.deepcopy(self.data)
            item = data['routes'][0] if kind == 'route' else data['routes'][0]['nodes'][0]
            del item['id']
            self.write(data)
            self.rejects('routes[0]', 'id')

    def test_legal_ascii_id_forms_and_boundaries_pass(self):
        for kind in ['route', 'node']:
            for value in ['A', '0', 'A_1.2', 'bad.id', 'end-', 'two--hyphens',
                          'A'*64, '9' + '._-'*21]:
                with self.subTest(kind=kind, value=value):
                    data = copy.deepcopy(self.data)
                    item = data['routes'][0] if kind == 'route' else data['routes'][0]['nodes'][0]
                    item['id'] = value
                    self.write(data)
                    self.assertEqual(len(check_project(self.root)), 6)

    def test_duplicate_route_id_is_rejected(self):
        self.data['routes'][1]['id'] = self.data['routes'][0]['id']
        self.write(self.data)
        self.rejects('routes[1]', 'rain-post-office', 'Duplicate')

    def test_duplicate_node_id_within_route_is_rejected(self):
        for route_index in range(len(self.data['routes'])):
            with self.subTest(route=route_index):
                data = copy.deepcopy(self.data)
                route = data['routes'][route_index]
                route['nodes'][1]['id'] = route['nodes'][0]['id']
                self.write(data)
                self.rejects(route['id'], route['nodes'][0]['id'], 'Duplicate')

    def test_node_id_may_repeat_across_routes(self):
        self.data['routes'][1]['nodes'][0]['id'] = self.data['routes'][0]['nodes'][0]['id']
        self.write(self.data)
        self.assertEqual(len(check_project(self.root)), 6)

    def test_threshold_rejects_nonintegers_and_out_of_range_values(self):
        for value in [True, False, 100.0, 100.5, 0, -100, 1, 99, 101,
                      1_000_001, 1_000_100, '100', None, [], {}]:
            with self.subTest(requiredSteps=value):
                data = copy.deepcopy(self.data)
                data['routes'][0]['nodes'][0]['requiredSteps'] = value
                self.write(data)
                self.rejects('rain-post-office', 'rain-post-office-eaves', 'requiredSteps')
        del self.data['routes'][0]['nodes'][0]['requiredSteps']
        self.write(self.data)
        self.rejects('rain-post-office-eaves', 'requiredSteps')

    def test_thresholds_must_strictly_increase_within_route(self):
        for value in [100, 200]:
            with self.subTest(last_threshold=value):
                data = copy.deepcopy(self.data)
                data['routes'][0]['nodes'][2]['requiredSteps'] = value
                self.write(data)
                self.rejects('rain-post-office', 'rain-post-office-rooftop', 'increasing')

    def test_legal_threshold_and_id_boundaries_pass(self):
        # Minimum positive floor and maximum are inclusive. Separate routes may
        # reuse a threshold; ordering is local to each narrative.
        for route in self.data['routes']:
            for node, steps in zip(route['nodes'], [100, 200, 1_000_000]):
                node['requiredSteps'] = steps
        self.data['routes'][0]['id'] = 'a'
        self.data['routes'][0]['nodes'][0]['id'] = 'a'*64
        self.write(self.data)
        self.assertEqual(len(check_project(self.root)), 6)

    def test_nonstandard_json_numbers_are_rejected(self):
        original = self.path.read_text(encoding='utf-8')
        for token in ['NaN', 'Infinity', '-Infinity', '1e400']:
            with self.subTest(token=token):
                self.path.write_text(original.replace('"requiredSteps": 100', f'"requiredSteps": {token}', 1),
                                     encoding='utf-8')
                self.rejects()

    def test_duplicate_json_keys_are_rejected(self):
        original = self.path.read_text(encoding='utf-8')
        for before, after, key in [
            ('"schemaVersion": 1', '"schemaVersion": 2, "schemaVersion": 1', 'schemaVersion'),
            ('"requiredSteps": 100', '"requiredSteps": 0, "requiredSteps": 100', 'requiredSteps'),
        ]:
            with self.subTest(key=key):
                self.path.write_text(original.replace(before, after, 1), encoding='utf-8')
                self.rejects('Duplicate JSON key', key)

    def test_unknown_fields_are_rejected_at_their_location(self):
        for level in ['root', 'route', 'node']:
            with self.subTest(level=level):
                data = copy.deepcopy(self.data)
                item = data if level == 'root' else data['routes'][0]
                if level == 'node':
                    item = item['nodes'][0]
                item['remoteURL'] = 'unused'
                self.write(data)
                self.rejects('remoteURL')

    def test_existing_file_outside_app_resources_is_rejected(self):
        graph = self.graph()
        _, build = self.journey_links(graph)
        self.resource_phase(graph, 'StairClimb')['files'].remove(build)
        self.save_graph(graph)
        self.assertTrue(self.path.is_file())
        self.rejects('StairClimb', 'PBXResourcesBuildPhase')

    def test_test_target_only_resource_is_rejected(self):
        graph = self.graph()
        _, build = self.journey_links(graph)
        self.resource_phase(graph, 'StairClimb')['files'].remove(build)
        self.resource_phase(graph, 'StairClimbTests')['files'].append(build)
        self.save_graph(graph)
        self.rejects('StairClimb', 'PBXResourcesBuildPhase')

    def test_wrong_resource_with_same_filename_is_rejected(self):
        graph = self.graph()
        reference, _ = self.journey_links(graph)
        # Keep the expected file present and bind an identical decoy via the
        # real Resources group. A basename or source-string check would pass.
        decoy = self.path.parent/'Decoy/ClimbJourneys.json'
        decoy.parent.mkdir()
        shutil.copyfile(self.path, decoy)
        graph['objects'][reference]['path'] = 'Decoy/ClimbJourneys.json'
        self.save_graph(graph)
        self.rejects('StairClimb', 'PBXResourcesBuildPhase')

    def test_build_file_bound_to_different_existing_resource_is_rejected(self):
        graph = self.graph()
        _, build = self.journey_links(graph)
        objects = graph['objects']
        wrong = next(key for key, value in objects.items()
                     if value.get('path') == 'Info-Debug.plist')
        objects[build]['fileRef'] = wrong
        self.save_graph(graph)
        self.rejects('StairClimb', 'PBXResourcesBuildPhase')

    def test_missing_file_is_rejected_with_filename(self):
        self.path.unlink()
        self.rejects('Missing')

    def test_orphan_build_file_and_phase_cannot_fake_app_membership(self):
        graph = self.graph()
        _, build = self.journey_links(graph)
        self.resource_phase(graph, 'StairClimb')['files'].remove(build)
        graph['objects']['ORPHAN'] = {'isa': 'PBXResourcesBuildPhase', 'files': [build]}
        self.save_graph(graph)
        self.rejects('StairClimb', 'PBXResourcesBuildPhase')

    def test_deployment_only_resources_are_not_normal_app_binding(self):
        graph = self.graph()
        self.resource_phase(graph, 'StairClimb')['runOnlyForDeploymentPostprocessing'] = '1'
        self.save_graph(graph)
        self.rejects('StairClimb', 'PBXResourcesBuildPhase')


if __name__ == '__main__':
    unittest.main()

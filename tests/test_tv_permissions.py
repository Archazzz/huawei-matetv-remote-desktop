import copy
import json
import unittest

from scripts.prepare_client import restrict_tv_permissions, patch_tv_clipboard_permissions


class TvPermissionTests(unittest.TestCase):
    def fixture(self):
        return {"module": {"deviceTypes": ["tv"], "requestPermissions": [
            {"name": "ohos.permission.INTERNET"},
            {"name": "ohos.permission.FILE_ACCESS_PERSIST"},
            {"name": "ohos.permission.READ_PASTEBOARD", "reason": "$string:reason",
             "usedScene": {"abilities": ["EntryAbility", "RemoteSessionAbility"], "when": "always"}},
            {"name": "ohos.permission.KEEP_BACKGROUND_RUNNING"},
            {"name": "example.retained", "reason": "Quoted bracket: \" ] } ,",
             "usedScene": {"abilities": ["EntryAbility"], "when": "inuse"}}],
            "metadata": [{"name": "unrelated", "value": "keep"}]}}

    def test_only_two_acl_entries_removed_with_nested_scene_and_quoted_brackets(self):
        original = self.fixture()
        expected = copy.deepcopy(original)
        expected["module"]["requestPermissions"] = [p for p in expected["module"]["requestPermissions"]
            if p["name"] not in {"ohos.permission.FILE_ACCESS_PERSIST", "ohos.permission.READ_PASTEBOARD"}]
        self.assertEqual(json.loads(restrict_tv_permissions(json.dumps(original))), expected)

    def test_upstream_trailing_comma_is_supported(self):
        text = json.dumps(self.fixture())
        text = text.replace('"when": "always"}', '"when": "always",}')
        text = text.replace('"when": "inuse"}}]', '"when": "inuse"}} , ]')
        result = restrict_tv_permissions(text)
        self.assertNotIn('ohos.permission.READ_PASTEBOARD', result)
        self.assertNotIn('ohos.permission.FILE_ACCESS_PERSIST', result)
        self.assertEqual(len(json.loads(result)["module"]["requestPermissions"]), 3)

    def test_non_tv_and_changed_upstream_fail_closed(self):
        for types in (["phone"], ["tv", "phone"], []):
            fixture = self.fixture()
            fixture["module"]["deviceTypes"] = types
            with self.subTest(types=types), self.assertRaises(ValueError):
                restrict_tv_permissions(json.dumps(fixture))
        fixture = self.fixture()
        fixture["module"]["requestPermissions"].pop(1)
        with self.assertRaises(ValueError):
            restrict_tv_permissions(json.dumps(fixture))
        fixture = self.fixture()
        fixture["module"]["requestPermissions"].append({"name": "ohos.permission.READ_PASTEBOARD"})
        with self.assertRaises(ValueError):
            restrict_tv_permissions(json.dumps(fixture))

    def test_clipboard_acl_request_is_short_circuited_before_os_calls(self):
        source = """import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
export async function ensureSystemPasteboardReadAccess(
  context: common.UIAbilityContext): Promise<ClipboardReadAccessDecision> {
  try {
    return await askSystemForPermission(context);
  } catch (_) { return resolveClipboardReadAccess(false, null); }
}
"""
        result = patch_tv_clipboard_permissions(source)
        self.assertLess(result.index("deviceInfo.deviceType === 'tv'"), result.index('askSystemForPermission'))
        self.assertIn('return await askSystemForPermission(context);', result)
        self.assertIn('return resolveClipboardReadAccess(false, null);', result)
        with self.assertRaises(ValueError):
            patch_tv_clipboard_permissions(source.replace('ClipboardReadAccessDecision', 'ChangedContract'))


if __name__ == '__main__':
    unittest.main()

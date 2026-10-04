"""Offline checks for the shell shared by the live-test runner and watchdog.

Run with python3 -B .github/tests/test_gitops_live_test.py.
"""

import os
from pathlib import Path
import re
import subprocess
import unittest


WORKFLOW = Path(__file__).resolve().parents[1] / "workflows/gitops-live-test.yml"
TEXT = WORKFLOW.read_text()
CONTROL = TEXT.split("cat > gitops-live-control.sh <<'SCRIPT'\n", 1)[1].split(
    "          SCRIPT\n", 1
)[0]
CONTROL = "\n".join(line[10:] for line in CONTROL.splitlines()) + "\n"
FUNCTIONS = CONTROL.split('\ncase "$1" in\n', 1)[0]
SHA = "a" * 40

# All API calls are shell functions. No kubectl, Flux CLI, or cluster is used.
MOCK = r'''
expected="$(revision_prefix "$BRANCH")$HEAD_SHA"
requested_children=''
verified_children=''
sleep() { :; }
k() {
  case "$1" in
    get)
      test "$2" = kustomizations.kustomize.toolkit.fluxcd.io
      test "$3" = -l
      test "$4" = 'kustomize.toolkit.fluxcd.io/name=apps,kustomize.toolkit.fluxcd.io/namespace=flux-system'
      [ "$BAD" != discovery ] || return 1
      [ "$CHILDREN" != none ] || return 0
      # The first discovery precedes the parent's apply of the child objects.
      [ "$attempts" -gt 0 ] || return 0
      printf '%s\n' kustomization.kustomize.toolkit.fluxcd.io/prowlarr \
        kustomization.kustomize.toolkit.fluxcd.io/radarr \
        kustomization.kustomize.toolkit.fluxcd.io/audiobookshelf
      ;;
    annotate)
      printf 'REQUEST %s %s\n' "$2" "$3"
      case "$2" in
        */prowlarr|*/radarr|*/audiobookshelf)
          requested_children="$requested_children $2"
          case "$3" in *-verify) verified_children="$verified_children $2" ;; esac
          ;;
      esac
      ;;
    wait)
      printf 'WAIT %s %s\n' "$2" "$3"
      if [ "$2" = kustomization.kustomize.toolkit.fluxcd.io/apps ] && [ "$PARENT" = waiting ] && [ "$CHILDREN" != none ]; then
        case "$requested_children" in *audiobookshelf*) ;; *) return 1 ;; esac
      fi
      if [ "$2" = kustomization.kustomize.toolkit.fluxcd.io/radarr ]; then
        case "$3:$BAD" in
          --for=condition=Ready:not-ready|*lastHandledReconcileAt*:unhandled) return 1 ;;
        esac
      fi
      ;;
    patch) printf 'PATCH %s\n' "$2" ;;
    *) echo "Unexpected API call: $*" >&2; return 1 ;;
  esac
}
field() {
  bad=''
  [ "$1" != kustomization.kustomize.toolkit.fluxcd.io/radarr ] || bad="$BAD"
  case "$2" in
    '{.metadata.generation}') printf 2 ;;
    '{.status.observedGeneration}')
      if [ "$bad" = stale-generation ]; then printf 1; else printf 2; fi ;;
    '{.status.conditions[?(@.type=="Ready")].observedGeneration}')
      if [ "$bad" = stale-ready ]; then printf 1; else printf 2; fi ;;
    '{.metadata.annotations.reconcile\.fluxcd\.io/requestedAt}') printf '' ;;
    '{.status.lastHandledReconcileAt}')
      if [ "$PARENT" != stuck ] && [ "$attempts" -gt 0 ]; then printf '%s' "$layer_token"; fi ;;
    '{.status.lastAppliedRevision}')
      if [ "$bad" = stale-revision ]; then printf '%s%s' "$(revision_prefix "$BRANCH")" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      elif [ "$1" = kustomization.kustomize.toolkit.fluxcd.io/apps ] && [ "$BAD" = parent-revision ]; then printf 'old'
      else printf '%s' "$expected"; fi ;;
    '{.spec.sourceRef.kind}')
      if [ "$bad" = source-kind ]; then printf OCIRepository; else printf GitRepository; fi ;;
    '{.spec.sourceRef.name}')
      if [ "$bad" = source-name ]; then printf other; else printf flux-system; fi ;;
    '{.spec.sourceRef.namespace}')
      if [ "$bad" = source-namespace ]; then printf other; else printf '%s' "$SOURCE_NAMESPACE"; fi ;;
    '{.spec.suspend}')
      if [ "$bad" = suspended ]; then printf true
      elif [ "$1" = "$root" ]; then printf '%s' "$ROOT_SUSPENDED"
      else printf false; fi ;;
    '{.status.artifact.revision}') printf '%s' "${ARTIFACT:-$expected}" ;;
    '{.spec.ref.name}') printf 'refs/heads/%s' "$BRANCH" ;;
    '{.spec.ref.branch}') printf '%s' "$BRANCH" ;;
    '{.spec.sync.ref}') printf 'refs/heads/%s' "$BRANCH" ;;
    '{.metadata.annotations.fluxcd\.controlplane\.io/reconcile}') printf '%s' "$INSTANCE_RECONCILE" ;;
    *) echo "Unexpected field: $*" >&2; return 1 ;;
  esac
}
'''


class LiveTestWorkflow(unittest.TestCase):
    def shell(self, command, **overrides):
        env = dict(os.environ, MODE="operator", HEAD_BRANCH="renovate/example", HEAD_SHA=SHA,
                   BRANCH="renovate/example", GITHUB_RUN_ID="42", GITHUB_RUN_ATTEMPT="1",
                   ORIGINAL_RECONCILE="null", ROOT_SUSPENDED="true", INSTANCE_RECONCILE="disabled",
                   PARENT="waiting", CHILDREN="present", BAD="", SOURCE_NAMESPACE="", ARTIFACT="")
        env.update(overrides)
        return subprocess.run(["sh", "-c", FUNCTIONS + MOCK + command], env=env,
                              text=True, capture_output=True, timeout=10)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_all_embedded_scripts_parse(self):
        result = subprocess.run(["sh", "-n"], input=CONTROL, text=True, capture_output=True)
        self.assert_success(result)
        scripts = re.findall(r"^        run: \|\n((?:          .*\n|\n)+)", TEXT, re.M)
        self.assertGreaterEqual(len(scripts), 6)
        for script in scripts:
            script = "\n".join(line[10:] for line in script.splitlines())
            script = re.sub(r"\$\{\{.*?\}\}", "test-value", script)
            with self.subTest(script=script[:60]):
                self.assert_success(subprocess.run(["bash", "-n"], input=script,
                                                   text=True, capture_output=True))
            for python in re.findall(r"<<'PY'[^\n]*\n(.*?)\nPY", script, re.S):
                compile(python, str(WORKFLOW), "exec")

    def test_revision_command_and_assertion(self):
        for mode, prefix in (("operator", "refs/heads/"), ("legacy", "")):
            with self.subTest(mode=mode):
                env = dict(os.environ, MODE=mode, HEAD_BRANCH="renovate/example", HEAD_SHA=SHA)
                result = subprocess.run(["sh", "-s", "revision"], input=CONTROL, env=env,
                                        text=True, capture_output=True)
                self.assert_success(result)
                self.assertEqual(result.stdout, f"{prefix}renovate/example@sha1:{SHA}\n")
                self.assert_success(self.shell("assert_pr", MODE=mode))
                for artifact in (f"{prefix}renovate/example@sha1:{'b' * 40}",
                                 f"{prefix}main@sha1:{SHA}",
                                 f"{'refs/heads/' if mode == 'legacy' else ''}renovate/example@sha1:{SHA}"):
                    self.assertNotEqual(self.shell("assert_pr", MODE=mode, ARTIFACT=artifact).returncode, 0)

    def test_children_requested_before_parent_wait_and_verified_after(self):
        result = self.shell('reconcile_layer apps test "$expected"')
        self.assert_success(result)
        output = result.stdout
        for name in ("prowlarr", "radarr", "audiobookshelf"):
            request = f"REQUEST kustomization.kustomize.toolkit.fluxcd.io/{name}"
            self.assertLess(output.index(request), output.index("WAIT kustomization.kustomize.toolkit.fluxcd.io/apps"))
            self.assertIn(f"{request} reconcile.fluxcd.io/requestedAt=test-verify", output)

    def test_old_parent_ready_does_not_hide_failed_children(self):
        for bad in ("not-ready", "unhandled", "stale-generation", "stale-ready", "stale-revision",
                    "source-kind", "source-name", "source-namespace", "suspended", "discovery", "parent-revision"):
            with self.subTest(bad=bad):
                result = self.shell('reconcile_layer apps test "$expected"', BAD=bad, PARENT="early-ready")
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_suspended_child_fails_without_requesting_or_unsuspending_it(self):
        commands = [('reconcile_layer apps test "$expected"', {})]
        commands += [("restore", dict(MODE=mode, BRANCH="main", ROOT_SUSPENDED="false",
                                     INSTANCE_RECONCILE="enabled")) for mode in ("operator", "legacy")]
        for command, args in commands:
            with self.subTest(command=command, args=args):
                result = self.shell(command, BAD="suspended", **args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Refusing to reconcile suspended child:", result.stderr)
                self.assertNotIn("REQUEST kustomization.kustomize.toolkit.fluxcd.io/radarr", result.stdout)
                self.assertNotIn("PATCH kustomization.kustomize.toolkit.fluxcd.io/radarr", result.stdout)

    def test_parent_timeout_fails(self):
        result = self.shell('reconcile_layer apps test "$expected"', PARENT="stuck")
        self.assertNotEqual(result.returncode, 0)

    def test_direct_resources_and_explicit_source_namespace(self):
        for children, namespace in (("none", ""), ("present", "flux-system")):
            with self.subTest(children=children, namespace=namespace):
                self.assert_success(self.shell('reconcile_layer apps test "$expected"',
                                               CHILDREN=children, SOURCE_NAMESPACE=namespace))

    def test_restore_checks_children_in_both_modes(self):
        for mode in ("operator", "legacy"):
            args = dict(MODE=mode, BRANCH="main", ROOT_SUSPENDED="false", INSTANCE_RECONCILE="enabled")
            with self.subTest(mode=mode):
                result = self.shell("restore", **args)
                self.assert_success(result)
                self.assertEqual(result.stdout.count("-verify"), 6)
                for bad in ("stale-revision", "stale-ready", "not-ready"):
                    self.assertNotEqual(self.shell("restore", BAD=bad, **args).returncode, 0)
                self.assertNotEqual(self.shell("restore", ARTIFACT=f"renovate/example@sha1:{SHA}", **args).returncode, 0)

    def test_runner_and_watchdog_use_shared_functions(self):
        self.assertIn('sh gitops-live-control.sh reconcile-layer "$k"', TEXT)
        self.assertIn('reconcile_layer "$layer" "${token}-${layer}" "$main_revision"', CONTROL)
        self.assertIn('(set -e; restore)', CONTROL)
        self.assertIn("Path('gitops-live-control.sh').read_text(), 'recovery', 'watchdog'", TEXT)
        self.assertIn('EXPECTED_REVISION="$(sh gitops-live-control.sh revision)"', TEXT)


if __name__ == "__main__":
    unittest.main()

"""Offline regression tests; all subprocesses are mocked except disposable local Git."""

from contextlib import redirect_stdout
from copy import deepcopy
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import yaml


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".github/scripts/flux-upgrade"
REAL_RUN = subprocess.run
REAL_TEMPORARY_DIRECTORY = tempfile.TemporaryDirectory
# Some agent-bundled Git binaries omit remote-http; the OS Git includes it.
LOCAL_GIT = "/usr/bin/git" if Path("/usr/bin/git").is_file() else "git"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


upgrade = load("flux_upgrade_under_test", SCRIPT / "run.py")
server = load("flux_fixture_server_under_test", SCRIPT / "serve.py")
BASE = {"operator": "0.61.0", "flux": "2.9.6"}
TARGET = {"operator": "0.62.0", "flux": "2.10.0"}
URL = "http://127.0.0.1:18000/repo.git"


def config(versions=None):
    versions = versions or BASE
    instance = upgrade.instance(versions["flux"], "https://example.invalid/never-contact.git")
    source = upgrade.resource("OCIRepository", "flux-operator", {
        "interval": "30m", "url": upgrade.CHART,
        "ref": {"tag": versions["operator"]},
        "layerSelector": {"mediaType": "application/vnd.cncf.helm.chart.content.v1.tar+gzip", "operation": "copy"},
    })
    release = upgrade.resource("HelmRelease", "flux-operator", {
        "interval": "30m", "releaseName": "flux-operator",
        "chartRef": {"kind": "OCIRepository", "name": "flux-operator"},
        "install": {"strategy": {"name": "RetryOnFailure"}},
        "upgrade": {"strategy": {"name": "RetryOnFailure"}}, "values": {},
    })
    return {"instance": instance, "source": source, "release": release}


def write_config(root, docs):
    directory = root / upgrade.MANIFESTS
    directory.mkdir(parents=True, exist_ok=True)
    for key, filename in upgrade.FILES.items():
        (directory / filename).write_text(yaml.safe_dump(docs[key]))


def ready_document(top_level=True):
    status = {"conditions": [{"type": "Ready", "status": "True", "observedGeneration": 4}]}
    if top_level:
        status["observedGeneration"] = 4
    return {"metadata": {"generation": 4}, "status": status}


def completed(stdout="", stderr="", returncode=0):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


class ScratchTest(unittest.TestCase):
    def setUp(self):
        self.scratch = REAL_TEMPORARY_DIRECTORY(prefix=".flux-upgrade-tests-", dir=ROOT)
        self.addCleanup(self.scratch.cleanup)
        self.work = Path(self.scratch.name)
        self.artifacts = self.work / "artifacts"
        self.artifacts.mkdir()

    def lab(self):
        return upgrade.Lab(self.work, self.artifacts)


class PlanTests(ScratchTest):
    def setUp(self):
        super().setUp()
        self.base, self.candidate = self.work / "base", self.work / "candidate"
        write_config(self.base, config())
        write_config(self.candidate, config(TARGET))

    def test_exact_stable_versions(self):
        self.assertEqual(upgrade.version("2.10.12"), (2, 10, 12))
        for value in (None, 2, 2.9, "", "v2.9.6", "2.9", "2.9.x", "latest", ">=2.9.6", "2.9.6-rc.1", "2.9.6+build", " 2.9.6", "2.9.6\n"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                upgrade.version(value)

    def test_combined_orders_operator_before_flux_and_copies_stages(self):
        stages = upgrade.plan(self.base, self.candidate, "combined")
        self.assertEqual(stages, [
            ("baseline", BASE),
            ("operator", {"operator": TARGET["operator"], "flux": BASE["flux"]}),
            ("flux", TARGET),
        ])
        self.assertIsNot(stages[0][1], stages[1][1])
        self.assertIsNot(stages[1][1], stages[2][1])

    def test_individual_scenarios_hold_other_component_fixed(self):
        for scenario in BASE:
            expected = dict(BASE, **{scenario: TARGET[scenario]})
            with self.subTest(scenario=scenario):
                self.assertEqual(upgrade.plan(self.base, self.candidate, scenario), [("baseline", BASE), (scenario, expected)])

    def test_unchanged_pair_is_baseline_smoke_for_every_scenario(self):
        write_config(self.candidate, config())
        for scenario in ("operator", "flux", "combined"):
            with self.subTest(scenario=scenario):
                self.assertEqual(upgrade.plan(self.base, self.candidate, scenario), [("baseline", BASE)])

    def test_single_change_skips_unchanged_stage(self):
        write_config(self.candidate, config(dict(BASE, flux=TARGET["flux"])))
        self.assertEqual([stage for stage, _ in upgrade.plan(self.base, self.candidate, "combined")], ["baseline", "flux"])
        self.assertEqual(upgrade.plan(self.base, self.candidate, "operator"), [("baseline", BASE)])

    def test_downgrades_rejected_even_when_other_scenario_selected(self):
        for component, value in (("operator", "0.60.9"), ("flux", "2.9.5")):
            write_config(self.candidate, config(dict(BASE, **{component: value})))
            for scenario in ("operator", "flux", "combined"):
                with self.subTest(component=component, scenario=scenario), self.assertRaisesRegex(ValueError, "Downgrades"):
                    upgrade.plan(self.base, self.candidate, scenario)

    def test_source_selectors_and_nonpublic_sources_rejected(self):
        for ref in ({"semver": "0.61.x"}, {"tag": "0.61.0", "digest": "sha256:" + "a" * 64}, {"tag": "latest"}):
            docs = config()
            docs["source"]["spec"]["ref"] = ref
            write_config(self.candidate, docs)
            with self.subTest(ref=ref), self.assertRaises((ValueError, KeyError)):
                upgrade.read_config(self.candidate)
        for key, path, value in (
            ("source", ("url",), "oci://example.invalid/private"),
            ("source", ("secretRef",), {"name": "credentials"}),
            ("instance", ("distribution", "registry"), "private.invalid/flux"),
            ("release", ("values",), {"imagePullSecrets": [{"name": "credentials"}]}),
        ):
            docs = config()
            target = docs[key]["spec"]
            for part in path[:-1]:
                target = target[part]
            target[path[-1]] = value
            write_config(self.candidate, docs)
            with self.subTest(key=key, path=path), self.assertRaises(ValueError):
                upgrade.read_config(self.candidate)

    def test_nonversion_changes_including_sync_and_kustomize_rejected(self):
        mutations = (
            lambda d: d["instance"]["spec"]["sync"].update(url="https://example.invalid/other.git"),
            lambda d: d["instance"]["spec"]["sync"].update(ref="refs/heads/other"),
            lambda d: d["instance"]["spec"]["kustomize"]["patches"][0].update(patch="arbitrary patch"),
            lambda d: d["instance"]["spec"]["cluster"].update(networkPolicy=False),
            lambda d: d["instance"]["spec"].update(components=["source-controller"]),
            lambda d: d["instance"]["spec"].update(extra="unsupported"),
            lambda d: d["source"]["spec"].update(interval="1m"),
            lambda d: d["release"]["spec"].update(interval="1m"),
            lambda d: d["release"]["spec"]["upgrade"]["strategy"].update(name="RemediateOnFailure"),
        )
        for index, mutate in enumerate(mutations):
            docs = config(TARGET)
            mutate(docs)
            write_config(self.candidate, docs)
            with self.subTest(mutation=index), self.assertRaises(ValueError):
                upgrade.plan(self.base, self.candidate, "combined")

    def test_identical_other_installation_files_allow_version_upgrade(self):
        for root in (self.base, self.candidate):
            for filename in ("kustomization.yaml", "nested/extra.yaml", "nested/flux-instance.yaml", ".guard"):
                path = root / upgrade.MANIFESTS / filename
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"unchanged\x00\xff\n")
        self.assertEqual(upgrade.plan(self.base, self.candidate, "combined")[-1], ("flux", TARGET))

    def test_other_installation_additions_deletions_and_changes_rejected(self):
        for filename in ("kustomization.yaml", "nested/extra.yaml", "nested/flux-instance.yaml", ".guard"):
            for operation in ("added", "deleted", "changed"):
                paths = [root / upgrade.MANIFESTS / filename for root in (self.base, self.candidate)]
                for path in paths:
                    path.parent.mkdir(parents=True, exist_ok=True)
                if operation != "added":
                    paths[0].write_bytes(b"original\x00\xff\n")
                if operation != "deleted":
                    paths[1].write_bytes(b"new\x00\xff\n")
                try:
                    for scenario in ("operator", "flux", "combined"):
                        with self.subTest(filename=filename, operation=operation, scenario=scenario):
                            with self.assertRaisesRegex(ValueError, "Other Flux installation file changes"):
                                upgrade.plan(self.base, self.candidate, scenario)
                finally:
                    for path in paths:
                        path.unlink(missing_ok=True)

    def test_other_installation_files_are_compared_byte_for_byte(self):
        write_config(self.candidate, config())
        baseline = self.base / upgrade.MANIFESTS / "kustomization.yaml"
        candidate = self.candidate / upgrade.MANIFESTS / "kustomization.yaml"
        baseline.write_bytes(b"resources: []\n")
        for contents in (b"# comment\nresources: []\n", b"resources: []\r\n", b"resources: []"):
            candidate.write_bytes(contents)
            self.assertEqual(yaml.safe_load(baseline.read_bytes()), yaml.safe_load(contents))
            with self.subTest(contents=contents), self.assertRaisesRegex(ValueError, "Other Flux installation file changes"):
                upgrade.plan(self.base, self.candidate, "combined")

    def test_resource_identity_and_extra_metadata_rejected(self):
        for key in upgrade.FILES:
            for field, value in (("kind", "Secret"), ("apiVersion", "invalid/v9"), ("metadata", {"name": "wrong", "namespace": "flux-system"})):
                docs = config()
                docs[key][field] = value
                write_config(self.candidate, docs)
                with self.subTest(key=key, field=field), self.assertRaises(ValueError):
                    upgrade.read_config(self.candidate)
            docs = config()
            docs[key]["metadata"]["annotations"] = {"extra": "unexpected"}
            write_config(self.candidate, docs)
            with self.subTest(key=key), self.assertRaises(ValueError):
                upgrade.read_config(self.candidate)

    def test_yaml_formatting_not_considered_semantic_change(self):
        write_config(self.candidate, config())
        path = self.candidate / upgrade.MANIFESTS / upgrade.FILES["source"]
        path.write_text("# formatting-only\n" + path.read_text())
        self.assertEqual(upgrade.plan(self.base, self.candidate, "combined"), [("baseline", BASE)])


class ReadinessTests(unittest.TestCase):
    def test_ready_with_and_without_top_level_observed_generation(self):
        self.assertTrue(upgrade.current_ready(ready_document()))
        self.assertTrue(upgrade.current_ready(ready_document(top_level=False)))

    def test_stale_generations_rejected(self):
        for target in ("top", "condition"):
            doc = ready_document()
            if target == "top":
                doc["status"]["observedGeneration"] = 3
            else:
                doc["status"]["conditions"][0]["observedGeneration"] = 3
            with self.subTest(target=target):
                self.assertFalse(upgrade.current_ready(doc))

    def test_false_missing_and_unobserved_ready_rejected(self):
        for condition in ({}, {"type": "Ready", "status": "False", "observedGeneration": 4},
                          {"type": "Ready", "status": "Unknown", "observedGeneration": 4},
                          {"type": "Ready", "status": "True"}):
            doc = ready_document()
            doc["status"]["conditions"] = [condition]
            with self.subTest(condition=condition):
                self.assertFalse(upgrade.current_ready(doc))
        self.assertFalse(upgrade.current_ready({}))
        doc = ready_document()
        del doc["metadata"]["generation"]
        self.assertFalse(upgrade.current_ready(doc))

    def test_reconciling_and_stalled_override_ready(self):
        for kind in ("Reconciling", "Stalled"):
            doc = ready_document()
            doc["status"]["conditions"].append({"type": kind, "status": "True"})
            with self.subTest(kind=kind):
                self.assertFalse(upgrade.current_ready(doc))
                doc["status"]["conditions"][-1]["status"] = "False"
                self.assertTrue(upgrade.current_ready(doc))

    def test_applied_version_exact_optional_v_and_digest(self):
        for value in ("2.9.6", "v2.9.6", "2.9.6@sha256:" + "a" * 64, "v2.9.6@sha256:" + "0123456789abcdef" * 4):
            with self.subTest(value=value):
                self.assertTrue(upgrade.applied_version(value, "2.9.6"))
        for value in ("2.9.60", "2.9.5", "prefix-v2.9.6", "2x9x6", "2.9.6-rc.1", "2.9.6+build", "2.9.6@sha256:abc", "2.9.6@sha1:" + "a" * 40, "2.9.6\n"):
            with self.subTest(value=value):
                self.assertFalse(upgrade.applied_version(value, "2.9.6"))


class FixtureTests(unittest.TestCase):
    def test_fixture_kinds_sources_and_scope_are_controlled(self):
        docs = upgrade.fixtures(BASE, URL, "baseline", True)
        self.assertEqual({doc["kind"] for doc in docs}, {"FluxInstance", "OCIRepository", "HelmRelease", "ConfigMap"})
        self.assertTrue(all(doc["metadata"]["namespace"] == "flux-system" for doc in docs))
        instance = next(doc for doc in docs if doc["kind"] == "FluxInstance")
        self.assertEqual(instance["spec"]["sync"]["url"], URL)
        self.assertEqual(instance["spec"]["sync"]["path"], "./clusters/test")
        self.assertEqual(instance["spec"]["sync"]["ref"], "refs/heads/main")
        source = next(doc for doc in docs if doc["kind"] == "OCIRepository")
        self.assertEqual(source["spec"]["url"], upgrade.CHART)
        probe = next(doc for doc in docs if doc["metadata"]["name"] == "probe")
        self.assertEqual(probe["spec"]["chart"]["spec"]["sourceRef"], {"kind": "GitRepository", "name": "flux-system"})
        self.assertEqual(probe["spec"]["driftDetection"], {"mode": "enabled"})
        forbidden = {"secretRef", "secretName", "imagePullSecrets", "storageClassName", "persistentVolumeClaim", "dnsNames", "hostPath"}
        def walk(value):
            if isinstance(value, dict):
                self.assertFalse(forbidden.intersection(value))
                for child in value.values():
                    walk(child)
            elif isinstance(value, list):
                for child in value:
                    walk(child)
            elif isinstance(value, str):
                self.assertNotIn("homelab", value)
                self.assertNotIn("github.com/ivan-penchev/gitops", value)
        walk(docs)

    def test_generated_root_disables_recursive_wait_to_avoid_ownership_cycle(self):
        instances = [upgrade.instance(BASE["flux"], URL)]
        for versions in (BASE, TARGET):
            instances.extend(doc for doc in upgrade.fixtures(versions, URL, "stage", False)
                             if doc["kind"] == "FluxInstance")
        for instance in instances:
            with self.subTest(version=instance["spec"]["distribution"]["version"]):
                root_spec = {"wait": True}
                for patch_doc in instance["spec"]["kustomize"]["patches"]:
                    target = patch_doc["target"]
                    self.assertEqual(target, {"group": "kustomize.toolkit.fluxcd.io",
                                              "kind": "Kustomization", "name": "flux-system"})
                    for operation in yaml.safe_load(patch_doc["patch"]):
                        self.assertIn(operation["op"], ("add", "replace"))
                        self.assertTrue(operation["path"].startswith("/spec/"))
                        root_spec[operation["path"].removeprefix("/spec/")] = operation["value"]
                self.assertIs(root_spec["wait"], False)
                self.assertEqual(root_spec["interval"], "10s")
                self.assertEqual(root_spec["timeout"], "5m")

    def test_pruning_fixture_toggle_and_version_inputs(self):
        for prune in (True, False):
            docs = upgrade.fixtures(TARGET, URL, "after", prune)
            names = {doc["metadata"]["name"] for doc in docs}
            self.assertEqual("prune-probe" in names, prune)
            self.assertEqual(docs[0]["spec"]["distribution"]["version"], TARGET["flux"])
            self.assertEqual(docs[1]["spec"]["ref"]["tag"], TARGET["operator"])
            self.assertEqual(next(doc for doc in docs if doc["metadata"]["name"] == "git-probe")["data"], {"stage": "after"})


class LabTests(ScratchTest):
    def test_environment_overrides_ambient_kubeconfig_and_git_credentials(self):
        with patch.dict(os.environ, {"KUBECONFIG": "/do-not-use/production", "GIT_ASKPASS": "credential-command", "GIT_CONFIG_COUNT": "10"}):
            lab = self.lab()
        self.assertEqual(lab.env["KUBECONFIG"], str(self.work / "kubeconfig"))
        self.assertNotIn("GIT_ASKPASS", lab.env)
        self.assertNotIn("GIT_CONFIG_COUNT", lab.env)
        self.assertEqual(lab.env["GIT_CONFIG_GLOBAL"], os.devnull)
        self.assertEqual(lab.env["GIT_CONFIG_NOSYSTEM"], "1")
        self.assertTrue(lab.name.startswith("flux-upgrade-"))
        self.assertNotEqual(lab.name, self.lab().name)
        self.assertEqual(lab.context, "kind-" + lab.name)

    def test_kubectl_always_passes_isolated_config_context_and_timeout(self):
        lab = self.lab()
        with patch.object(lab, "run", return_value=completed()) as run:
            lab.k("get", "pods", check=False)
        args = run.call_args.args
        self.assertEqual(args[:5], ("kubectl", "--kubeconfig", str(self.work / "kubeconfig"), "--context", lab.context))
        self.assertIn("--request-timeout=30s", args)
        self.assertEqual(args[-4:], ("-n", "flux-system", "get", "pods"))
        self.assertFalse(run.call_args.kwargs["check"])

    def test_subprocess_receives_isolated_environment_and_failure_policy(self):
        lab = self.lab()
        with patch.object(upgrade.subprocess, "run", return_value=completed("out", "err", 7)) as run:
            with self.assertRaisesRegex(RuntimeError, "Command failed: harmless probe"):
                lab.run("harmless", "probe", timeout=9)
            self.assertEqual(run.call_args.kwargs["env"], lab.env)
            self.assertEqual(run.call_args.kwargs["timeout"], 9)
            self.assertEqual(lab.run("harmless", check=False).returncode, 7)

    def test_bootstrap_helm_and_apply_use_isolated_context(self):
        lab = self.lab()
        lab.url = URL
        with patch.object(lab, "run", return_value=completed()) as run:
            lab.bootstrap(BASE)
        calls = [call.args for call in run.call_args_list]
        helm = calls[0]
        self.assertEqual(helm[:4], ("helm", "install", "flux-operator", upgrade.CHART))
        self.assertEqual(helm[helm.index("--version") + 1], BASE["operator"])
        self.assertEqual(helm[helm.index("--kubeconfig") + 1], lab.env["KUBECONFIG"])
        self.assertEqual(helm[helm.index("--kube-context") + 1], lab.context)
        for command in calls[1:]:
            self.assertEqual(command[0], "kubectl")
            self.assertIn(lab.context, command)
            self.assertIn(lab.env["KUBECONFIG"], command)
        self.assertIn("--dry-run=server", calls[2])
        self.assertIn("--field-manager=kustomize-controller", calls[3])
        manifest = yaml.safe_load(run.call_args_list[-1].kwargs["input"])
        self.assertEqual(manifest["spec"]["sync"]["url"], URL)

    def test_get_distinguishes_missing_object_from_api_failure(self):
        lab = self.lab()
        with patch.object(lab, "k", return_value=completed("  ")):
            self.assertEqual(lab.get("configmap", "missing"), {})
        with patch.object(lab, "k", return_value=completed('{"metadata":{"name":"probe"}}')):
            self.assertEqual(lab.get("configmap", "probe")["metadata"]["name"], "probe")
        with patch.object(lab, "k", side_effect=RuntimeError("API unavailable")), self.assertRaises(RuntimeError):
            lab.get("configmap", "missing")

    def test_ready_combines_current_generation_with_custom_predicate(self):
        lab = self.lab()
        for current, match in ((True, True), (True, False), (False, True)):
            doc = ready_document()
            if not current:
                doc["status"]["observedGeneration"] = 3
            predicate = Mock(return_value=match)
            with patch.object(lab, "get", return_value=doc), patch.object(lab, "wait") as wait:
                lab.ready("fluxinstance", "flux", predicate)
                self.assertEqual(wait.call_args.args[1](), current and match)
                self.assertEqual(predicate.called, current)

    def test_wait_retries_transient_error_and_times_out(self):
        lab = self.lab()
        with patch.object(upgrade.time, "monotonic", side_effect=[0, 0, 1]), patch.object(upgrade.time, "sleep"), redirect_stdout(io.StringIO()):
            lab.wait("probe", Mock(side_effect=[RuntimeError("transient"), True]), seconds=3)
        with patch.object(upgrade.time, "monotonic", side_effect=[0, 0, 4]), patch.object(upgrade.time, "sleep"), redirect_stdout(io.StringIO()), self.assertRaisesRegex(TimeoutError, "transient"):
            lab.wait("probe", Mock(side_effect=RuntimeError("transient")), seconds=3)

    def test_cleanup_attempts_all_owned_resources_despite_errors(self):
        for error in (OSError("docker missing"), subprocess.TimeoutExpired("docker", 1), completed(stderr="remove failed", returncode=1)):
            lab = self.lab()
            lab.server_attempted = lab.cluster_attempted = lab.image_attempted = True
            with patch.object(lab, "run", side_effect=[error, completed(), completed()]) as run, self.subTest(error=type(error).__name__), self.assertRaises(RuntimeError):
                lab.cleanup()
            self.assertEqual([call.args for call in run.call_args_list], [
                ("docker", "rm", "--force", lab.server),
                ("kind", "delete", "cluster", "--name", lab.name),
                ("docker", "image", "rm", lab.image),
            ])
            self.assertTrue(all(call.kwargs == {"check": False, "timeout": 120} for call in run.call_args_list))

    def test_cleanup_is_noop_before_start_and_tolerates_absent_resources(self):
        lab = self.lab()
        with patch.object(lab, "run") as run:
            lab.cleanup()
            run.assert_not_called()
        lab.cluster_attempted = True
        with patch.object(lab, "run", return_value=completed(stderr="No such cluster", returncode=1)):
            lab.cleanup()

    def test_partial_creation_failures_are_marked_for_cleanup(self):
        for failure in ("kind", "build", "container", "copy"):
            with self.subTest(failure=failure):
                directory = self.work / failure
                directory.mkdir()
                lab = upgrade.Lab(directory, self.artifacts)
                def execute(*args, **kwargs):
                    if (failure == "kind" and args[:3] == ("kind", "create", "cluster")) or (failure == "build" and args[:2] == ("docker", "build")) or (failure == "container" and args[:2] == ("docker", "run")) or (failure == "copy" and args[:2] == ("docker", "cp")):
                        raise RuntimeError("partial creation")
                    if args[0] == "kubectl":
                        return completed(lab.context)
                    return completed()
                with patch.object(upgrade.shutil, "which", return_value="/fake/tool"), patch.object(lab, "run", side_effect=execute), redirect_stdout(io.StringIO()), self.assertRaisesRegex(RuntimeError, "partial"):
                    lab.start(upgrade.NODE)
                self.assertTrue(lab.cluster_attempted)
                self.assertEqual(lab.image_attempted, failure in ("build", "container", "copy"))
                self.assertEqual(lab.server_attempted, failure in ("container", "copy"))
                with patch.object(lab, "run", return_value=completed()) as cleanup:
                    lab.cleanup()
                self.assertEqual(len(cleanup.call_args_list), {"kind": 1, "build": 2, "container": 3, "copy": 3}[failure])

    def test_context_mismatch_aborts_before_git_or_server(self):
        lab = self.lab()
        with patch.object(upgrade.shutil, "which", return_value="/fake/tool"), patch.object(lab, "run", return_value=completed("wrong-context")) as run, redirect_stdout(io.StringIO()), self.assertRaisesRegex(RuntimeError, "context mismatch"):
            lab.start(upgrade.NODE)
        self.assertTrue(lab.cluster_attempted)
        self.assertFalse(lab.image_attempted)
        self.assertFalse(any(call.args[0] == "git" for call in run.call_args_list))

    def test_diagnostics_only_collect_allowlisted_resources_and_logs(self):
        lab = self.lab()
        with patch.object(lab, "k") as k:
            lab.diagnostics()
            k.assert_not_called()
        lab.cluster_attempted = True
        with patch.object(lab, "k", return_value=completed("{}")) as k:
            lab.diagnostics()
        resources = [call.args[1] for call in k.call_args_list if call.args[0] == "get"]
        self.assertEqual(set(resources), {"fluxinstances", "gitrepositories", "ocirepositories", "kustomizations", "helmreleases", "helmcharts", "deployments", "pods", "events"})
        self.assertNotIn("secrets", resources)
        files = list(self.artifacts.iterdir())
        self.assertEqual(len(files), len(resources) + 1 + len(upgrade.COMPONENTS))
        self.assertTrue(all(path.suffix in (".json", ".log") for path in files))
        self.assertFalse((self.artifacts / "kubeconfig").exists())

    def test_diagnostic_timeout_does_not_skip_other_collections(self):
        lab = self.lab()
        lab.cluster_attempted = True
        with patch.object(lab, "k", side_effect=[subprocess.TimeoutExpired("kubectl", 35)] + [completed("{}")] * 13) as k, redirect_stdout(io.StringIO()):
            lab.diagnostics()
        self.assertEqual(k.call_count, 14)
        self.assertTrue((self.artifacts / "notification-controller.log").exists())

    def test_fixture_checks_exact_revision_chart_values_and_pruning(self):
        lab = self.lab()
        revision = "refs/heads/main@sha1:" + "a" * 40
        chart_version = "0.1.2+" + "a" * 12
        docs = {
            ("gitrepository", "flux-system"): ready_document(),
            ("kustomization", "flux-system"): ready_document(),
            ("helmrelease", "probe"): ready_document(),
            ("configmap", "git-probe"): {"data": {"stage": "after"}},
            ("configmap", "helm-probe"): {"data": {"stage": "after", "chart": chart_version}},
            ("configmap", "prune-probe"): {},
        }
        docs[("gitrepository", "flux-system")]["status"]["artifact"] = {"revision": revision}
        docs[("kustomization", "flux-system")]["status"]["lastAppliedRevision"] = revision
        docs[("helmrelease", "probe")]["status"]["history"] = [{"chartVersion": chart_version, "status": "deployed"}]
        def check(objects, prune=False):
            with patch.object(lab, "get", side_effect=lambda kind, name: objects[(kind, name)]), patch.object(lab, "wait", side_effect=lambda description, predicate: self.assertTrue(predicate(), description)):
                lab.verify_fixture(revision, "after", chart_version, prune)
        check(docs)
        mutations = (
            lambda d: d[("gitrepository", "flux-system")]["status"]["artifact"].update(revision="wrong"),
            lambda d: d[("kustomization", "flux-system")]["status"].update(lastAppliedRevision="wrong"),
            lambda d: d[("helmrelease", "probe")]["status"]["history"][0].update(chartVersion="0.1.2"),
            lambda d: d[("helmrelease", "probe")]["status"]["history"][0].update(chartVersion="0.1.2+" + "b" * 12),
            lambda d: d[("helmrelease", "probe")]["status"]["history"][0].update(status="failed"),
            lambda d: d[("configmap", "git-probe")]["data"].update(stage="drift"),
            lambda d: d[("configmap", "helm-probe")]["data"].update(chart="0.1.2"),
            lambda d: d[("configmap", "helm-probe")]["data"].update(chart="0.1.2+" + "b" * 12),
            lambda d: d[("configmap", "prune-probe")].update(metadata={"name": "prune-probe"}),
        )
        for index, mutate in enumerate(mutations):
            changed = deepcopy(docs)
            mutate(changed)
            with self.subTest(index=index), self.assertRaises(AssertionError):
                check(changed)
        docs[("configmap", "prune-probe")] = {"metadata": {"name": "prune-probe"}}
        check(docs, prune=True)

    def test_exercise_bootstraps_only_baseline_and_proves_drift_injection(self):
        seed = ("refs/heads/main@sha1:" + "a" * 40, "0.1.1+" + "a" * 12)
        after = ("refs/heads/main@sha1:" + "b" * 40, "0.1.2+" + "b" * 12)
        for label in ("baseline", "operator"):
            lab = self.lab()
            with patch.object(lab, "publish", side_effect=[seed, after]) as publish, patch.object(lab, "bootstrap") as bootstrap, patch.object(lab, "verify_fixture") as fixture, patch.object(lab, "verify_versions") as versions, patch.object(lab, "k", return_value=completed('{"data":{"stage":"drift"}}')) as k, patch.object(lab, "wait") as wait, redirect_stdout(io.StringIO()):
                result = lab.exercise(label, BASE)
            self.assertEqual(bootstrap.call_count, int(label == "baseline"))
            self.assertEqual([call.args for call in publish.call_args_list], [(BASE, label + "-seed", True), (BASE, label, False)])
            self.assertEqual([call.args for call in fixture.call_args_list], [
                (seed[0], label + "-seed", seed[1], True),
                (after[0], label, after[1], False),
                (after[0], label, after[1], False),
            ])
            self.assertEqual(versions.call_count, 2)
            self.assertEqual([call.args[2] for call in k.call_args_list], ["git-probe", "helm-probe"])
            self.assertEqual(wait.call_count, 2)
            self.assertEqual(result["git_revision"], after[0])
            self.assertEqual(result["chart_version"], after[1])


class VersionVerificationTests(ScratchTest):
    def setUp(self):
        super().setUp()
        self.subject = self.lab()
        self.docs = {}
        components = [{"name": name, "repository": "ghcr.io/fluxcd/" + name,
                       "tag": "v1.2.3", "digest": "sha256:" + "a" * 64}
                      for name in upgrade.COMPONENTS]
        instance = ready_document(top_level=False)
        instance["status"].update(lastAppliedRevision="v" + BASE["flux"], components=components)
        self.docs[("fluxinstance", "flux")] = instance
        source = ready_document()
        source["status"]["artifact"] = {"revision": BASE["operator"] + "@sha256:" + "a" * 64}
        self.docs[("ocirepository", "flux-operator")] = source
        release = ready_document()
        self.chart_version = BASE["operator"] + "+" + "a" * 12
        release["status"]["history"] = [{"chartVersion": self.chart_version, "status": "deployed"}]
        self.docs[("helmrelease", "flux-operator")] = release
        for component in components:
            self.docs[("deployment", component["name"])] = self.deployment(
                component["name"], component["repository"] + ":" + component["tag"])
        self.operator = self.deployment("flux-operator", "ghcr.io/controlplaneio-fluxcd/flux-operator:v" + BASE["operator"])
        self.docs[("deployment", "flux-operator")] = deepcopy(self.operator)
        self.releases = [{"name": "flux-operator", "chart": "flux-operator-" + self.chart_version, "status": "deployed"}]
        self.pods = [{"metadata": {}, "status": {"containerStatuses": [{"ready": True, "imageID": "sha256:" + "a" * 64}]}}]
        self.commands = []

    @staticmethod
    def deployment(name, image):
        return {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": name},
                "spec": {"selector": {"matchLabels": {"app": name}},
                         "template": {"spec": {"containers": [{"name": "manager", "image": image}]}}}}

    def verify(self):
        def run(*args, **kwargs):
            self.commands.append(args)
            self.assertEqual(args[0], "helm")
            self.assertEqual(args[args.index("--kubeconfig") + 1], self.subject.env["KUBECONFIG"])
            self.assertEqual(args[args.index("--kube-context") + 1], self.subject.context)
            if args[1] == "list":
                return completed(json.dumps(self.releases))
            if args[1:3] == ("get", "manifest"):
                return completed(yaml.safe_dump(self.operator))
            raise AssertionError(f"Unexpected Helm command: {args}")
        def kubectl(*args, **kwargs):
            self.commands.append(args)
            if args[:2] == ("get", "pods"):
                return completed(json.dumps({"items": self.pods}))
            if args[0] in ("rollout", "wait"):
                return completed()
            raise AssertionError(f"Unexpected kubectl command: {args}")
        def wait(description, predicate, **kwargs):
            self.assertTrue(predicate(), description)
        with patch.object(self.subject, "run", side_effect=run), patch.object(self.subject, "k", side_effect=kubectl), patch.object(self.subject, "get", side_effect=lambda kind, name: deepcopy(self.docs[(kind, name)])), patch.object(self.subject, "wait", side_effect=wait):
            self.subject.verify_versions(BASE)

    def test_expected_versions_images_and_ready_pods_pass(self):
        self.verify()
        rollouts = [command[2] for command in self.commands if command[:2] == ("rollout", "status")]
        self.assertEqual(set(rollouts), {"deployment/flux-operator", *["deployment/" + name for name in upgrade.COMPONENTS]})
        established = [command for command in self.commands if command[0] == "wait"]
        self.assertEqual(set(established), {
            ("wait", "crd/" + name, "--for=condition=Established", "--timeout=60s")
            for name in ("fluxinstances.fluxcd.controlplane.io", "gitrepositories.source.toolkit.fluxcd.io",
                         "ocirepositories.source.toolkit.fluxcd.io", "kustomizations.kustomize.toolkit.fluxcd.io",
                         "helmreleases.helm.toolkit.fluxcd.io")
        })

    def test_wrong_flux_or_source_revision_rejected(self):
        for key in (("fluxinstance", "flux"), ("ocirepository", "flux-operator")):
            original = deepcopy(self.docs[key])
            if key[0] == "fluxinstance":
                self.docs[key]["status"]["lastAppliedRevision"] = "2.9.60"
            else:
                self.docs[key]["status"]["artifact"]["revision"] = "0.61.00"
            with self.subTest(key=key), self.assertRaises(AssertionError):
                self.verify()
            self.docs[key] = original

    def test_helm_chart_version_and_deployed_status_required(self):
        for field, value in (("chart", "flux-operator-0.60.0"), ("status", "pending-upgrade")):
            original = deepcopy(self.releases)
            self.releases[0][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(AssertionError, "expected Operator chart"):
                self.verify()
            self.releases = original

    def test_old_successful_release_history_cannot_mask_latest_failure(self):
        self.docs[("helmrelease", "flux-operator")]["status"]["history"] = [
            {"chartVersion": self.chart_version, "status": "failed"},
            {"chartVersion": self.chart_version, "status": "deployed"},
        ]
        with self.assertRaises(AssertionError):
            self.verify()

    def test_operator_chart_must_match_source_digest_suffix(self):
        for chart_version in (BASE["operator"], BASE["operator"] + "+" + "b" * 12):
            self.docs[("helmrelease", "flux-operator")]["status"]["history"][0]["chartVersion"] = chart_version
            with self.subTest(chart_version=chart_version), self.assertRaisesRegex(AssertionError, "helmrelease/flux-operator"):
                self.verify()

    def test_operator_image_drift_is_rejected(self):
        self.docs[("deployment", "flux-operator")]["spec"]["template"]["spec"]["containers"][0]["image"] = "wrong.invalid/operator:v0.1.0"
        with self.assertRaisesRegex(AssertionError, "Operator Deployment images"):
            self.verify()

    def test_controller_set_and_image_mismatch_rejected(self):
        original = deepcopy(self.docs[("fluxinstance", "flux")])
        self.docs[("fluxinstance", "flux")]["status"]["components"].pop()
        with self.assertRaisesRegex(AssertionError, "controller set"):
            self.verify()
        self.docs[("fluxinstance", "flux")] = original
        self.docs[("deployment", "source-controller")]["spec"]["template"]["spec"]["containers"][0]["image"] = "ghcr.io/fluxcd/source-controller:v0.0.1"
        with self.assertRaisesRegex(AssertionError, "image does not match"):
            self.verify()

    def test_digest_pinned_controller_images_are_accepted(self):
        for component in self.docs[("fluxinstance", "flux")]["status"]["components"]:
            self.docs[("deployment", component["name"])]["spec"]["template"]["spec"]["containers"][0]["image"] += "@" + component["digest"]
        self.verify()

    def test_missing_unready_or_terminating_pods_rejected(self):
        for pods in ([], [{"metadata": {}, "status": {}}],
                     [{"metadata": {}, "status": {"containerStatuses": [{"ready": False, "imageID": "digest"}]}}],
                     [{"metadata": {}, "status": {"containerStatuses": [{"ready": True}]}}],
                     [{"metadata": {"deletionTimestamp": "now"}, "status": {"containerStatuses": [{"ready": True, "imageID": "digest"}]}}]):
            self.pods = pods
            with self.subTest(pods=pods), self.assertRaisesRegex(AssertionError, "unready controller Pods"):
                self.verify()


class MainTests(ScratchTest):
    def invoke(self, lab, stages=None):
        stages = stages or [("baseline", BASE)]
        args = ["run.py", "--base", "unused-base", "--candidate", "unused-candidate", "--scenario", "combined", "--artifacts", str(self.artifacts)]
        def scratch(**kwargs):
            return REAL_TEMPORARY_DIRECTORY(dir=self.work, **kwargs)
        with patch.object(sys, "argv", args), patch.object(upgrade, "plan", return_value=stages), patch.object(upgrade, "Lab", return_value=lab), patch.object(upgrade.tempfile, "TemporaryDirectory", side_effect=scratch), patch.object(upgrade.signal, "signal") as signals, redirect_stdout(io.StringIO()):
            self.signals = signals
            upgrade.main()

    def fake_lab(self):
        lab = Mock()
        lab.name = "flux-upgrade-offline"
        lab.exercise.side_effect = lambda label, versions: {"stage": label, "versions": versions}
        return lab

    def report(self):
        return json.loads((self.artifacts / "summary.json").read_text())

    def test_success_smoke_summary_and_finally_order(self):
        lab = self.fake_lab()
        self.invoke(lab)
        report = self.report()
        self.assertTrue(report["passed"])
        self.assertEqual(report["mode"], "baseline-smoke")
        self.assertEqual([call[0] for call in lab.method_calls], ["start", "exercise", "diagnostics", "cleanup"])
        self.assertEqual(report["cluster"], lab.name)
        self.assertEqual(report["node_image"], upgrade.NODE)
        self.assertEqual(self.signals.call_args_list[-2].args, (signal.SIGTERM, signal.SIG_IGN))
        self.assertEqual(self.signals.call_args_list[-1].args, (signal.SIGINT, signal.SIG_IGN))

    def test_upgrade_summary_retains_ordered_stage_results(self):
        lab = self.fake_lab()
        stages = [("baseline", BASE), ("operator", dict(BASE, operator=TARGET["operator"])), ("flux", TARGET)]
        self.invoke(lab, stages)
        self.assertEqual(self.report()["mode"], "upgrade")
        self.assertEqual([result["stage"] for result in self.report()["results"]], ["baseline", "operator", "flux"])

    def test_start_and_exercise_failures_still_diagnose_cleanup_report(self):
        for method in ("start", "exercise"):
            lab = self.fake_lab()
            getattr(lab, method).side_effect = RuntimeError("injected " + method)
            with self.subTest(method=method), self.assertRaisesRegex(RuntimeError, "injected"):
                self.invoke(lab)
            lab.diagnostics.assert_called_once()
            lab.cleanup.assert_called_once()
            self.assertFalse(self.report()["passed"])
            self.assertEqual(self.report()["error"], "injected " + method)

    def test_cleanup_failure_makes_successful_exercise_fail_and_persists_summary(self):
        lab = self.fake_lab()
        lab.cleanup.side_effect = RuntimeError("cleanup failure")
        with self.assertRaisesRegex(RuntimeError, "cleanup failure"):
            self.invoke(lab)
        self.assertFalse(self.report()["passed"])
        self.assertEqual(self.report()["cleanup_error"], "cleanup failure")
        self.assertEqual(len(self.report()["results"]), 1)

    def test_diagnostics_failure_still_cleans_up_and_writes_summary(self):
        lab = self.fake_lab()
        lab.diagnostics.side_effect = OSError("artifact write failed")
        with self.assertRaisesRegex(OSError, "artifact write failed"):
            self.invoke(lab)
        lab.cleanup.assert_called_once()
        report = self.report()
        self.assertIs(report["passed"], False)
        self.assertEqual(report["diagnostics_error"], "artifact write failed")
        self.assertEqual(report["results"], [{"stage": "baseline", "versions": BASE}])
        self.assertEqual([call[0] for call in lab.method_calls], ["start", "exercise", "diagnostics", "cleanup"])

    def test_diagnostics_failure_preserves_original_exercise_error(self):
        lab = self.fake_lab()
        lab.exercise.side_effect = RuntimeError("exercise failed")
        lab.diagnostics.side_effect = OSError("artifact write failed")
        with self.assertRaisesRegex(OSError, "artifact write failed"):
            self.invoke(lab)
        lab.cleanup.assert_called_once()
        report = self.report()
        self.assertIs(report["passed"], False)
        self.assertEqual(report["error"], "exercise failed")
        self.assertEqual(report["diagnostics_error"], "artifact write failed")
        self.assertEqual(report["results"], [])

    def test_sigterm_handler_enters_failure_cleanup_path(self):
        lab = self.fake_lab()
        def terminate(*args):
            handler = self.signals.call_args_list[0].args[1]
            handler(signal.SIGTERM, None)
        lab.start.side_effect = terminate
        with self.assertRaises(InterruptedError):
            self.invoke(lab)
        self.assertFalse(self.report()["passed"])
        self.assertIn("Interrupted by signal", self.report()["error"])
        lab.diagnostics.assert_called_once()
        lab.cleanup.assert_called_once()


class GitHTTPTests(ScratchTest):
    def setUp(self):
        super().setUp()
        self.lab_instance = self.lab()
        self.git_env = self.lab_instance.env
        self.repo = self.work / "repo"
        self.bare = self.work / "repo.git"
        self.git("init", "--initial-branch=main", str(self.repo))
        self.git("init", "--bare", "--initial-branch=main", str(self.bare))
        self.git("-C", str(self.repo), "remote", "add", "origin", str(self.bare))
        class QuietHandler(server.Handler):
            def log_message(self, *args):
                pass
        self.httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), QuietHandler)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}/repo.git"
        self.lab_instance.url = self.url
        self.copy_commands = []
        def backend_run(args, **kwargs):
            if list(args[:4]) == ["docker", "exec", self.lab_instance.server, "git"]:
                self.assertEqual(list(args[4:]), ["ls-remote", "http://127.0.0.1:8000/repo.git", "refs/heads/main"])
                return REAL_RUN([LOCAL_GIT, "ls-remote", self.url, "refs/heads/main"], **kwargs)
            if list(args[:2]) == ["docker", "cp"]:
                self.copy_commands.append(list(args))
                # The loopback server reads the local bare repo; no container exists.
                return completed()
            if args[0] != "git":
                raise AssertionError(f"Unexpected non-Git subprocess in offline test: {args}")
            if list(args) == ["git", "http-backend"]:
                env = dict(kwargs["env"])
                env.pop("GIT_EXEC_PATH", None)
                env.update(GIT_PROJECT_ROOT=str(self.work), GIT_CONFIG_VALUE_0=str(self.bare))
                kwargs["env"] = env
            return REAL_RUN([LOCAL_GIT, *args[1:]], **kwargs)
        self.backend_patch = patch.object(server.subprocess, "run", side_effect=backend_run)
        self.backend_patch.start()
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)
        self.backend_patch.stop()

    def git(self, *args):
        result = REAL_RUN([LOCAL_GIT, *args], capture_output=True, text=True, env=self.git_env, timeout=20)
        self.assertEqual(result.returncode, 0, f"git {args}: {result.stderr}")
        return result.stdout.strip()

    def test_git_ls_remote_clone_fetch_and_second_fixture_commit(self):
        revision1, chart1 = self.lab_instance.publish(BASE, "seed", True)
        sha1 = revision1.split("sha1:")[1]
        self.assertIn(sha1, self.git("ls-remote", self.url, "refs/heads/main"))
        clone = self.work / "clone"
        self.git("clone", self.url, str(clone))
        self.assertEqual(self.git("-C", str(clone), "rev-parse", "HEAD"), sha1)
        docs = list(yaml.safe_load_all((clone / "clusters/test/resources.yaml").read_text()))
        self.assertIn("prune-probe", [doc["metadata"]["name"] for doc in docs])
        self.assertEqual(docs[0]["spec"]["sync"]["url"], self.url)
        revision2, chart2 = self.lab_instance.publish(TARGET, "after", False)
        self.assertNotEqual(revision1, revision2)
        self.assertNotEqual(chart1, chart2)
        self.git("-C", str(clone), "fetch", "origin")
        self.assertEqual(self.git("-C", str(clone), "rev-parse", "origin/main"), revision2.split("sha1:")[1])
        contents = self.git("-C", str(clone), "show", "origin/main:clusters/test/resources.yaml")
        docs = list(yaml.safe_load_all(contents))
        self.assertNotIn("prune-probe", [doc["metadata"]["name"] for doc in docs])
        self.assertEqual(docs[0]["spec"]["distribution"]["version"], TARGET["flux"])
        chart = yaml.safe_load(self.git("-C", str(clone), "show", "origin/main:chart/Chart.yaml"))
        self.assertEqual(chart["version"], "0.1.2")
        self.assertEqual(chart2, chart["version"] + "+" + revision2.split("sha1:")[1][:12])
        templates = self.git("-C", str(clone), "ls-tree", "-r", "--name-only", "origin/main", "chart/templates")
        self.assertIn("chart/templates/configmap.yaml", templates)
        self.assertEqual(self.copy_commands, [
            ["docker", "cp", str(self.bare / directory) + "/.",
             self.lab_instance.server + ":/srv/repo.git/" + directory]
            for directory in ("objects", "refs", "objects", "refs")
        ])

    def test_healthz_is_local_and_ready(self):
        with urlopen(self.url.removesuffix("/repo.git") + "/healthz", timeout=5) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.read(), b"ready\n")

    def test_receive_pack_and_unexpected_paths_are_forbidden(self):
        origin = self.url.removesuffix("/repo.git")
        for path, data in (("/repo.git/info/refs?service=git-receive-pack", None),
                           ("/repo.git/git-receive-pack", b"0000"),
                           ("/other.git/info/refs?service=git-upload-pack", None),
                           ("/repo.git/HEAD", None),
                           ("/repo.git/../config", None),
                           ("/repo.git/info/refs?service=git-upload-pack&extra=1", None)):
            with self.subTest(path=path), self.assertRaises(HTTPError) as raised:
                urlopen(Request(origin + path, data=data), timeout=5)
            self.assertEqual(raised.exception.code, 403)
            raised.exception.close()


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = yaml.load((ROOT / ".github/workflows/flux-upgrade-test.yml").read_text(), Loader=yaml.BaseLoader)
        cls.job = cls.workflow["jobs"]["upgrade"]
        cls.steps = cls.job["steps"]

    def test_triggers_are_unprivileged_and_root_scoped(self):
        self.assertEqual(set(self.workflow["on"]), {"pull_request", "workflow_dispatch"})
        self.assertEqual(self.workflow["on"]["pull_request"]["branches"], ["main"])
        self.assertEqual(set(self.workflow["on"]["pull_request"]["paths"]), {
            "kubernetes/clusters/homelab/flux-system/**", ".github/workflows/flux-upgrade-test.yml",
            ".github/scripts/flux-upgrade/**", ".github/tests/test_flux_upgrade.py",
        })
        self.assertEqual(self.workflow["on"]["workflow_dispatch"]["inputs"]["baseline_ref"]["default"], "main")

    def test_hosted_readonly_independent_matrix(self):
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertEqual(self.job["runs-on"], "ubuntu-24.04")
        self.assertEqual(self.job["timeout-minutes"], "40")
        self.assertEqual(self.job["strategy"]["fail-fast"], "false")
        self.assertEqual(self.job["strategy"]["matrix"]["scenario"], ["operator", "flux", "combined"])
        self.assertNotIn("if", self.job)
        self.assertNotIn("environment", self.job)
        self.assertNotIn("permissions", self.job)
        self.assertNotIn("secrets.", json.dumps(self.workflow))

    def test_immutable_candidate_and_base_checkouts_do_not_persist_credentials(self):
        checkouts = [step for step in self.steps if step.get("uses", "").startswith("actions/checkout@")]
        self.assertEqual(len(checkouts), 2)
        candidate, baseline = [step["with"] for step in checkouts]
        self.assertEqual(candidate["path"], "candidate")
        self.assertEqual(candidate["ref"], "${{ github.event.pull_request.head.sha || github.sha }}")
        self.assertEqual(candidate["repository"], "${{ github.event.pull_request.head.repo.full_name || github.repository }}")
        self.assertEqual(baseline["path"], "baseline")
        self.assertEqual(baseline["ref"], "${{ github.event.pull_request.base.sha || inputs.baseline_ref }}")
        self.assertEqual(baseline["repository"], "${{ github.repository }}")
        self.assertTrue(all(step["with"]["persist-credentials"] == "false" for step in checkouts))

    def test_offline_tests_precede_integration_and_scripts_parse(self):
        commands = [step["run"] for step in self.steps if "run" in step]
        offline = next(i for i, text in enumerate(commands) if "test_flux_upgrade.py" in text)
        integration = next(i for i, text in enumerate(commands) if "flux-upgrade/run.py" in text)
        self.assertLess(offline, integration)
        self.assertIn("python3 -B", commands[offline])
        for command in commands:
            REAL_RUN(["bash", "-n"], input=command, text=True, check=True, capture_output=True)

    def test_artifacts_only_explicit_diagnostics_directory(self):
        uploads = [step for step in self.steps if step.get("uses", "").startswith("actions/upload-artifact@")]
        self.assertEqual(len(uploads), 1)
        upload = uploads[0]
        self.assertEqual(upload["if"], "always()")
        self.assertEqual(upload["with"]["path"], "${{ runner.temp }}/flux-upgrade-${{ matrix.scenario }}/")
        self.assertEqual(upload["with"]["retention-days"], "7")
        self.assertNotIn("include-hidden-files", upload["with"])

    def test_existing_live_test_keeps_root_change_rejection(self):
        live = yaml.load((ROOT / ".github/workflows/gitops-live-test.yml").read_text(), Loader=yaml.BaseLoader)
        guards = [step for job in live["jobs"].values() for step in job.get("steps", [])
                  if step.get("name") == "Authorize PR and reject changes the suspended root cannot test"]
        self.assertEqual(len(guards), 1)
        script = guards[0]["with"]["script"]
        self.assertIn("startsWith('kubernetes/clusters/homelab/')", script)
        self.assertIn("core.setFailed('Root and FluxInstance changes need a separate migration/controller test.", script)


if __name__ == "__main__":
    unittest.main(verbosity=2)

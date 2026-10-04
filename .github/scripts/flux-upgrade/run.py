"""Exercise version-only Flux upgrades in a disposable, credential-free kind cluster."""

import argparse
from copy import deepcopy
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

import yaml


MANIFESTS = Path("kubernetes/clusters/homelab/flux-system")
CHART = "oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator"
NODE = "kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed"
COMPONENTS = ["source-controller", "kustomize-controller", "helm-controller", "notification-controller"]
KINDS = {
    "FluxInstance": "fluxcd.controlplane.io/v1",
    "OCIRepository": "source.toolkit.fluxcd.io/v1",
    "HelmRelease": "helm.toolkit.fluxcd.io/v2",
    "ConfigMap": "v1",
}
FILES = {"instance": "flux-instance.yaml", "source": "flux-operator-source.yaml", "release": "flux-operator.yaml"}


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError("Upgrade tests require exact stable x.y.z versions")
    return tuple(map(int, value.split(".")))


def read_config(root):
    docs = {key: yaml.safe_load((Path(root) / MANIFESTS / file).read_text()) for key, file in FILES.items()}
    for key, kind in (("instance", "FluxInstance"), ("source", "OCIRepository"), ("release", "HelmRelease")):
        doc = docs[key]
        name = "flux" if key == "instance" else "flux-operator"
        if doc["apiVersion"] != KINDS[kind] or doc["kind"] != kind or doc["metadata"] != {"name": name, "namespace": "flux-system"}:
            raise ValueError(f"Unsupported {key} identity or metadata")
    instance, source, release = (docs[key]["spec"] for key in ("instance", "source", "release"))
    flux, operator = instance["distribution"]["version"], source["ref"]["tag"]
    version(flux)
    version(operator)
    if instance["distribution"] != {"version": flux, "registry": "ghcr.io/fluxcd"}:
        raise ValueError("Only the public upstream Flux distribution is supported")
    if instance["components"] != COMPONENTS or instance["cluster"] != {
        "type": "kubernetes", "multitenant": False, "networkPolicy": True, "domain": "cluster.local"
    }:
        raise ValueError("Controller or cluster configuration needs a dedicated test design")
    if set(instance) != {"distribution", "components", "cluster", "sync", "kustomize"}:
        raise ValueError("Unsupported FluxInstance fields")
    expected_source = {"interval": "30m", "url": CHART, "ref": {"tag": operator},
                       "layerSelector": {"mediaType": "application/vnd.cncf.helm.chart.content.v1.tar+gzip", "operation": "copy"}}
    expected_release = {"interval": "30m", "releaseName": "flux-operator",
                        "chartRef": {"kind": "OCIRepository", "name": "flux-operator"},
                        "install": {"strategy": {"name": "RetryOnFailure"}},
                        "upgrade": {"strategy": {"name": "RetryOnFailure"}}, "values": {}}
    if source != expected_source or release != expected_release:
        raise ValueError("Operator source/release configuration needs a dedicated test design")
    return docs, {"operator": operator, "flux": flux}


def plan(base, candidate, scenario):
    old, baseline = read_config(base)
    new, target = read_config(candidate)

    def other_files(root):
        directory = Path(root) / MANIFESTS
        return {str(path.relative_to(directory)): path.read_bytes() for path in directory.rglob("*")
                if path.is_file() and str(path.relative_to(directory)) not in FILES.values()}

    if other_files(base) != other_files(candidate):
        raise ValueError("Other Flux installation file changes need a dedicated test design")
    normalized = deepcopy(new)
    normalized["instance"]["spec"]["distribution"]["version"] = baseline["flux"]
    normalized["source"]["spec"]["ref"]["tag"] = baseline["operator"]
    if normalized != old:
        raise ValueError("Only Operator chart tag and Flux distribution version changes are covered; other changes are not tested")
    for key in baseline:
        if version(target[key]) < version(baseline[key]):
            raise ValueError(f"Downgrades are not covered: {key}")
    stages = [("baseline", dict(baseline))]
    current = dict(baseline)
    for key in ("operator", "flux"):
        if scenario in (key, "combined") and target[key] != current[key]:
            current[key] = target[key]
            stages.append((key, dict(current)))
    return stages


def resource(kind, name, spec=None, data=None):
    doc = {"apiVersion": KINDS[kind], "kind": kind, "metadata": {"name": name, "namespace": "flux-system"}}
    if spec is not None:
        doc["spec"] = spec
    if data is not None:
        doc["data"] = data
    return doc


def instance(flux, url):
    return resource("FluxInstance", "flux", {
        "distribution": {"version": flux, "registry": "ghcr.io/fluxcd"},
        "components": COMPONENTS,
        "cluster": {"type": "kubernetes", "multitenant": False, "networkPolicy": True, "domain": "cluster.local"},
        "sync": {"kind": "GitRepository", "name": "flux-system", "url": url,
                 "ref": "refs/heads/main", "path": "./clusters/test", "interval": "10s"},
        "kustomize": {"patches": [{
            "target": {"group": "kustomize.toolkit.fluxcd.io", "kind": "Kustomization", "name": "flux-system"},
            # The root owns its FluxInstance; waiting for that instance creates a readiness cycle.
            "patch": "- op: add\n  path: /spec/interval\n  value: 10s\n- op: add\n  path: /spec/timeout\n  value: 5m\n- op: add\n  path: /spec/wait\n  value: false\n"
        }]},
    })


def fixtures(versions, url, stage, prune):
    source = resource("OCIRepository", "flux-operator", {
        "interval": "10s", "url": CHART, "ref": {"tag": versions["operator"]},
        "layerSelector": {"mediaType": "application/vnd.cncf.helm.chart.content.v1.tar+gzip", "operation": "copy"},
    })
    strategy = {"strategy": {"name": "RetryOnFailure"}}
    operator = resource("HelmRelease", "flux-operator", {
        "interval": "10s", "releaseName": "flux-operator", "chartRef": {"kind": "OCIRepository", "name": "flux-operator"},
        "install": strategy, "upgrade": strategy, "values": {},
    })
    probe = resource("HelmRelease", "probe", {
        "interval": "10s", "releaseName": "probe", "chart": {"spec": {
            "chart": "./chart", "reconcileStrategy": "Revision",
            "sourceRef": {"kind": "GitRepository", "name": "flux-system"},
        }}, "install": strategy, "upgrade": strategy,
        "driftDetection": {"mode": "enabled"}, "values": {"stage": stage},
    })
    docs = [instance(versions["flux"], url), source, operator, probe,
            resource("ConfigMap", "git-probe", data={"stage": stage})]
    if prune:
        docs.append(resource("ConfigMap", "prune-probe", data={"stage": stage}))
    return docs


def current_ready(doc):
    generation = doc.get("metadata", {}).get("generation")
    status = doc.get("status", {})
    # FluxInstance has no top-level status.observedGeneration; other Flux CRDs do.
    if "observedGeneration" in status and status["observedGeneration"] != generation:
        return False
    conditions = status.get("conditions", [])
    if any(c.get("type") in ("Reconciling", "Stalled") and c.get("status") == "True" for c in conditions):
        return False
    return generation is not None and any(c.get("type") == "Ready" and c.get("status") == "True"
                                         and c.get("observedGeneration") == generation for c in conditions)


def applied_version(revision, expected):
    return bool(re.fullmatch(r"v?" + re.escape(expected) + r"(?:@sha256:[a-f0-9]{64})?", revision))


class Lab:
    def __init__(self, work, artifacts):
        self.work, self.artifacts = Path(work), Path(artifacts)
        self.name = "flux-upgrade-" + uuid.uuid4().hex[:12]
        self.context = "kind-" + self.name
        self.server = self.name + "-git"
        self.image = self.name + ":fixture"
        self.env = dict(os.environ, KUBECONFIG=str(self.work / "kubeconfig"), KIND_EXPERIMENTAL_PROVIDER="docker")
        # Never inherit credentials for the ambient cluster or fixture Git operations.
        for key in list(self.env):
            if key.startswith("GIT_"):
                del self.env[key]
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME="Flux upgrade fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                        GIT_COMMITTER_NAME="Flux upgrade fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
        self.cluster_attempted = False
        self.server_attempted = False
        self.image_attempted = False
        self.counter = 0
        self.repo = self.work / "repo"

    def run(self, *args, input=None, timeout=180, check=True):
        result = subprocess.run(list(args), input=input, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=self.env, timeout=timeout)
        if check and result.returncode:
            raise RuntimeError(f"Command failed: {' '.join(args)}\n{result.stdout}\n{result.stderr}")
        return result

    def k(self, *args, **kwargs):
        return self.run("kubectl", "--kubeconfig", self.env["KUBECONFIG"], "--context", self.context,
                        "--request-timeout=30s", "-n", "flux-system", *args, **kwargs)

    def get(self, kind, name):
        result = self.k("get", kind, name, "--ignore-not-found", "-o", "json")
        return json.loads(result.stdout) if result.stdout.strip() else {}

    def wait(self, description, predicate, seconds=360):
        print(f"Waiting for {description}", flush=True)
        deadline = time.monotonic() + seconds
        last_error = "condition not met"
        while time.monotonic() < deadline:
            try:
                if predicate():
                    return
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                last_error = str(error)
            time.sleep(5)
        raise TimeoutError(f"Timed out waiting for {description}: {last_error}")

    def ready(self, kind, name, predicate=lambda doc: True):
        self.wait(f"{kind}/{name} current Ready", lambda: (lambda doc: current_ready(doc) and predicate(doc))(self.get(kind, name)))

    def start(self, node):
        for tool in ("docker", "kind", "helm", "kubectl", "git"):
            if not shutil.which(tool):
                raise RuntimeError(f"Missing required tool: {tool}")
        self.run("docker", "info", timeout=30)
        self.cluster_attempted = True
        print(f"Creating disposable cluster {self.name}", flush=True)
        self.run("kind", "create", "cluster", "--name", self.name, "--image", node,
                 "--kubeconfig", self.env["KUBECONFIG"], "--wait", "180s", timeout=420)
        if self.k("config", "current-context").stdout.strip() != self.context:
            raise RuntimeError("Disposable cluster context mismatch")
        self.repo.mkdir()
        self.run("git", "init", "--initial-branch=main", str(self.repo))
        self.run("git", "init", "--bare", "--initial-branch=main", str(self.work / "repo.git"))
        self.run("git", "-C", str(self.repo), "remote", "add", "origin", str(self.work / "repo.git"))
        self.image_attempted = True
        self.run("docker", "build", "--tag", self.image, str(Path(__file__).parent), timeout=300)
        self.server_attempted = True
        self.run("docker", "run", "--detach", "--name", self.server, "--network", "kind", self.image)
        self.run("docker", "cp", str(self.work / "repo.git"), self.server + ":/srv/repo.git")
        self.wait("fixture HTTP readiness", lambda: self.run(
            "docker", "exec", self.server, "python", "-c",
            "import urllib.request; assert urllib.request.urlopen('http://127.0.0.1:8000/healthz').status == 200",
            check=False).returncode == 0, seconds=60)
        ip = self.run("docker", "inspect", "--format", '{{(index .NetworkSettings.Networks "kind").IPAddress}}', self.server).stdout.strip()
        if not ip:
            raise RuntimeError("Fixture has no kind-network address")
        self.url = f"http://{ip}:8000/repo.git"

    def publish(self, versions, stage, prune):
        self.counter += 1
        chart_version = f"0.1.{self.counter}"
        root = self.repo / "clusters/test"
        root.mkdir(parents=True, exist_ok=True)
        (root / "resources.yaml").write_text(yaml.safe_dump_all(fixtures(versions, self.url, stage, prune)))
        chart = self.repo / "chart"
        (chart / "templates").mkdir(parents=True, exist_ok=True)
        (chart / "Chart.yaml").write_text(yaml.safe_dump({"apiVersion": "v2", "name": "probe", "version": chart_version}))
        (chart / "templates/configmap.yaml").write_text(
            'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: helm-probe\ndata:\n  stage: {{ .Values.stage | quote }}\n  chart: {{ .Chart.Version | quote }}\n')
        self.run("git", "-C", str(self.repo), "add", ".")
        self.run("git", "-C", str(self.repo), "commit", "-m", stage)
        self.run("git", "-C", str(self.repo), "push", "origin", "main")
        # Publish objects before refs so readers never see a commit with missing objects.
        for directory in ("objects", "refs"):
            self.run("docker", "cp", str(self.work / "repo.git" / directory) + "/.",
                     self.server + ":/srv/repo.git/" + directory)
        sha = self.run("git", "-C", str(self.repo), "rev-parse", "HEAD").stdout.strip()
        served = self.run("docker", "exec", self.server, "git", "ls-remote",
                          "http://127.0.0.1:8000/repo.git", "refs/heads/main").stdout.strip()
        if served != sha + "\trefs/heads/main":
            raise AssertionError("Fixture Git server did not publish the expected commit")
        return f"refs/heads/main@sha1:{sha}", f"{chart_version}+{sha[:12]}"

    def bootstrap(self, versions):
        self.run("helm", "install", "flux-operator", CHART, "--version", versions["operator"],
                 "--kubeconfig", self.env["KUBECONFIG"], "--kube-context", self.context,
                 "--namespace", "flux-system", "--create-namespace", "--wait", "--timeout", "5m", timeout=360)
        self.k("wait", "crd/fluxinstances.fluxcd.controlplane.io", "--for=condition=Established", "--timeout=60s")
        manifest = yaml.safe_dump(instance(versions["flux"], self.url))
        self.k("apply", "--server-side", "--dry-run=server", "--validate=strict", "-f", "-", input=manifest)
        self.k("apply", "--server-side", "--field-manager=kustomize-controller", "-f", "-", input=manifest)

    def verify_versions(self, versions):
        self.ready("fluxinstance", "flux", lambda doc: applied_version(doc.get("status", {}).get("lastAppliedRevision", ""), versions["flux"]))
        self.ready("ocirepository", "flux-operator", lambda doc: applied_version(doc.get("status", {}).get("artifact", {}).get("revision", ""), versions["operator"]))
        source_revision = self.get("ocirepository", "flux-operator")["status"]["artifact"]["revision"]
        deployed_chart = versions["operator"] + "+" + source_revision.split("@sha256:")[1][:12]
        self.ready("helmrelease", "flux-operator", lambda doc: any(
            item.get("chartVersion") == deployed_chart and item.get("status") == "deployed"
            for item in doc.get("status", {}).get("history", [])[:1]))
        release = json.loads(self.run("helm", "list", "--kubeconfig", self.env["KUBECONFIG"], "--kube-context", self.context,
                                     "-n", "flux-system", "-o", "json").stdout)
        if not any(item["name"] == "flux-operator" and item["chart"] == "flux-operator-" + deployed_chart
                   and item["status"] == "deployed" for item in release):
            raise AssertionError("Helm did not deploy the expected Operator chart")
        self.k("rollout", "status", "deployment/flux-operator", "--timeout=180s", timeout=210)
        operator = self.get("deployment", "flux-operator")
        rendered = list(yaml.safe_load_all(self.run(
            "helm", "get", "manifest", "flux-operator", "--kubeconfig", self.env["KUBECONFIG"],
            "--kube-context", self.context, "-n", "flux-system").stdout))
        expected_operator = next(doc for doc in rendered if doc and doc.get("kind") == "Deployment"
                                 and doc["metadata"]["name"] == "flux-operator")
        operator_images = {item["name"]: item["image"]
                           for item in operator["spec"]["template"]["spec"]["containers"]}
        expected_images = {item["name"]: item["image"]
                           for item in expected_operator["spec"]["template"]["spec"]["containers"]}
        if operator_images != expected_images:
            raise AssertionError("Operator Deployment images differ from the deployed chart")
        for crd in ("fluxinstances.fluxcd.controlplane.io", "gitrepositories.source.toolkit.fluxcd.io",
                    "ocirepositories.source.toolkit.fluxcd.io", "kustomizations.kustomize.toolkit.fluxcd.io",
                    "helmreleases.helm.toolkit.fluxcd.io"):
            self.k("wait", "crd/" + crd, "--for=condition=Established", "--timeout=60s")
        components = self.get("fluxinstance", "flux")["status"]["components"]
        if {item["name"] for item in components} != set(COMPONENTS):
            raise AssertionError("FluxInstance reported an unexpected controller set")
        for component in components:
            name = component["name"]
            self.k("rollout", "status", "deployment/" + name, "--timeout=180s", timeout=210)
            deployment = self.get("deployment", name)
            images = [c["image"] for c in deployment["spec"]["template"]["spec"]["containers"]]
            expected = component["repository"] + ":" + component["tag"]
            if not any(image == expected or image == expected + "@" + component.get("digest", "") for image in images):
                raise AssertionError(f"{name} image does not match the applied Flux distribution")
            selector = ",".join(f"{key}={value}" for key, value in deployment["spec"]["selector"]["matchLabels"].items())
            pods = json.loads(self.k("get", "pods", "-l", selector, "-o", "json").stdout)["items"]
            active = [pod for pod in pods if not pod["metadata"].get("deletionTimestamp")]
            if not active or any(not all(s.get("ready") and s.get("imageID") for s in pod.get("status", {}).get("containerStatuses", []))
                                 or not pod.get("status", {}).get("containerStatuses") for pod in active):
                raise AssertionError(f"{name} has unready controller Pods")

    def verify_fixture(self, revision, stage, chart_version, prune):
        self.ready("gitrepository", "flux-system", lambda doc: doc["status"].get("artifact", {}).get("revision") == revision)
        self.ready("kustomization", "flux-system", lambda doc: doc["status"].get("lastAppliedRevision") == revision)
        self.ready("helmrelease", "probe", lambda doc: any(
            item.get("chartVersion") == chart_version and item.get("status") == "deployed"
            for item in doc.get("status", {}).get("history", [])[:1]))
        self.wait("Git and Helm fixture values", lambda:
                  self.get("configmap", "git-probe").get("data") == {"stage": stage} and
                  self.get("configmap", "helm-probe").get("data") == {"stage": stage, "chart": chart_version})
        self.wait("fixture pruning state", lambda: bool(self.get("configmap", "prune-probe")) == prune)

    def exercise(self, label, versions):
        print(f"Testing {label}: {versions}", flush=True)
        revision, chart = self.publish(versions, label + "-seed", True)
        if label == "baseline":
            self.bootstrap(versions)
        self.verify_fixture(revision, label + "-seed", chart, True)
        self.verify_versions(versions)
        revision, chart = self.publish(versions, label, False)
        self.verify_fixture(revision, label, chart, False)
        for name in ("git-probe", "helm-probe"):
            result = json.loads(self.k("patch", "configmap", name, "--type=merge", "-p",
                                      json.dumps({"data": {"stage": "drift"}}), "-o", "json").stdout)
            if result["data"]["stage"] != "drift":
                raise AssertionError("Drift injection was not observed")
            self.wait(name + " automatic drift repair", lambda: self.get("configmap", name).get("data", {}).get("stage") == label)
        self.verify_fixture(revision, label, chart, False)
        self.verify_versions(versions)
        return {"stage": label, "versions": versions, "git_revision": revision, "chart_version": chart}

    def diagnostics(self):
        if self.server_attempted:
            try:
                result = self.run("docker", "logs", "--tail=200", self.server, check=False, timeout=35)
                (self.artifacts / "fixture-server.log").write_text(result.stdout + result.stderr)
            except (OSError, subprocess.TimeoutExpired) as error:
                print(f"Fixture diagnostic collection failed: {error}", flush=True)
        if not self.cluster_attempted:
            return
        for kind in ("fluxinstances", "gitrepositories", "ocirepositories", "kustomizations", "helmreleases", "helmcharts", "deployments", "pods", "events"):
            try:
                result = self.k("get", kind, "-o", "json", check=False, timeout=35)
                (self.artifacts / (kind + ".json")).write_text(result.stdout + result.stderr)
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                print(f"Diagnostic collection failed: {error}", flush=True)
        for name in ["flux-operator", *COMPONENTS]:
            try:
                result = self.k("logs", "deployment/" + name, "--all-containers", "--tail=200", check=False, timeout=35)
                (self.artifacts / (name + ".log")).write_text(result.stdout + result.stderr)
            except subprocess.TimeoutExpired:
                pass

    def cleanup(self):
        errors = []
        commands = []
        if self.server_attempted:
            commands.append(("docker", "rm", "--force", self.server))
        if self.cluster_attempted:
            commands.append(("kind", "delete", "cluster", "--name", self.name))
        if self.image_attempted:
            commands.append(("docker", "image", "rm", self.image))
        for command in commands:
            try:
                result = self.run(*command, check=False, timeout=120)
                if result.returncode and "No such" not in result.stderr:
                    errors.append(result.stderr)
            except (OSError, subprocess.TimeoutExpired) as error:
                errors.append(str(error))
        if errors:
            raise RuntimeError("Disposable resource cleanup failed: " + "; ".join(errors))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--scenario", choices=("operator", "flux", "combined"), required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--node-image", default=NODE)
    args = parser.parse_args()
    stages = plan(args.base, args.candidate, args.scenario)
    args.artifacts.mkdir(parents=True, exist_ok=True)
    report = {"scenario": args.scenario, "mode": "upgrade" if len(stages) > 1 else "baseline-smoke",
              "plan": stages, "results": [], "passed": False, "node_image": args.node_image}
    print(json.dumps(report, indent=2), flush=True)

    def interrupted(signum, frame):
        raise InterruptedError(f"Interrupted by signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    with tempfile.TemporaryDirectory(prefix="flux-upgrade-") as work:
        lab = Lab(work, args.artifacts)
        report["cluster"] = lab.name
        try:
            lab.start(args.node_image)
            for label, versions in stages:
                report["results"].append(lab.exercise(label, versions))
            report["passed"] = True
        except BaseException as error:
            report["error"] = str(error)
            raise
        finally:
            # A second cancellation must not skip the bounded best-effort cleanup.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            try:
                lab.diagnostics()
            except Exception as error:
                report["passed"] = False
                report["diagnostics_error"] = str(error)
                raise
            finally:
                try:
                    lab.cleanup()
                except Exception as error:
                    report["passed"] = False
                    report["cleanup_error"] = str(error)
                    raise
                finally:
                    (args.artifacts / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Disposable upgrade test passed; cluster and fixture removed.", flush=True)


if __name__ == "__main__":
    main()

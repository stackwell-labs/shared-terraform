"""Tests for scripts/deploy-lambda against a fake aws, terraform and cargo.

Each test builds a throwaway service repo (with a bare origin) and runs the
real engine on it; stub.py stands in for the AWS and build tools. Run:

  python3 -m unittest discover -s scripts/tests -v
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENGINE = HERE.parent / "deploy-lambda"
PIN = "0" * 40
ACCOUNT = "111122223333"

MANIFEST = f"""\
engine = "{{engine}}"

[live]
account = "{ACCOUNT}"
profile = "svc"
region = "us-east-1"
infra = "infra/aws"
var_file = "live.tfvars"
cargo_manifest = "Cargo.toml"
smoke = "scripts/smoke.sh"
allow_replace = ["aws_lambda_permission.allowed"]

[live.bins.svc-service]
zip_var = "lambda_zip_path"
function_output = "lambda_function_name"

[live.bins.svc-tick]
zip_var = "tick_zip_path"
function_output = "tick_function_name"
"""

SMOKE = """\
#!/usr/bin/env bash
env | grep -E '^(DEPLOY_|AWS_PROFILE=)' | sort > "$STUB_DIR/smoke-env"
exit "${SMOKE_EXIT:-0}"
"""

FUNCTIONS = {
    "fn-service": {"output": "lambda_function_name", "zip_var": "lambda_zip_path"},
    "fn-tick": {"output": "tick_function_name", "zip_var": "tick_zip_path"},
}


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True,
                          text=True).stdout.strip()


def init_repo(path, origin):
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True)
    subprocess.run(["git", "init", "-q", "-b", "main", str(path)], check=True)
    git(path, "config", "user.email", "test@example.invalid")
    git(path, "config", "user.name", "test")
    git(path, "remote", "add", "origin", str(origin))


def commit_all(path, push=True):
    git(path, "add", "-A")
    git(path, "commit", "-q", "-m", "change")
    if push:
        git(path, "push", "-q", "origin", "HEAD:main")
    return git(path, "rev-parse", "HEAD")


class Fixture:
    """A service repo, a stub dir, and a way to run the engine on them."""

    def __init__(self, root, engine=PIN, manifest=None):
        self.root = root
        self.repo = root / "svc"
        self.stub = root / "stub"
        self.bin = root / "bin"
        for d in (self.stub, self.bin):
            d.mkdir()
        for tool in ("aws", "terraform", "cargo"):
            (self.bin / tool).symlink_to(HERE / "stub.py")
        init_repo(self.repo, root / "svc.git")
        self.write(".amber/deploy.toml", manifest or MANIFEST.format(engine=engine))
        self.write("scripts/smoke.sh", SMOKE)
        (self.repo / "scripts/smoke.sh").chmod(0o755)
        self.write("infra/aws/backend.hcl", "")
        self.write("Cargo.toml", "")
        self.sha = commit_all(self.repo)
        self.scenario = {"account": ACCOUNT, "functions": FUNCTIONS}
        self.env = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                        STUB_DIR=str(self.stub), DEPLOY_LAMBDA_PINNED=engine)
        self.env.pop("CARGO_TARGET_DIR", None)

    def write(self, rel, text):
        p = self.repo / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def run(self, target="live", engine=ENGINE, **env):
        (self.stub / "scenario.json").write_text(json.dumps(self.scenario))
        (self.stub / "calls.log").unlink(missing_ok=True)
        return subprocess.run([sys.executable, str(engine), target], cwd=self.repo,
                              env=dict(self.env, **env), capture_output=True, text=True)

    def calls(self, tool=None):
        log = self.stub / "calls.log"
        if not log.exists():
            return []
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        return [c for c in calls if tool is None or c["tool"] == tool]

    def applied(self):
        return any("apply" in c["args"] for c in self.calls("terraform"))


def change(address, *actions):
    return {"address": address, "change": {"actions": list(actions)}}


class DeployLambdaTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="deploy-lambda-test-"))
        self.f = Fixture(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def assertRefused(self, out, needle):
        self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
        self.assertIn("refusing", out.stderr)
        self.assertIn(needle, out.stderr)

    # --- the happy path ---------------------------------------------------

    def test_deploys_and_smokes(self):
        self.f.scenario["changes"] = [change("aws_lambda_function.svc", "update")]
        out = self.f.run()
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn(f"{self.f.sha} is live on live", out.stdout)
        self.assertTrue(self.f.applied())
        # Every AWS-touching call runs as the manifest's profile.
        self.assertEqual({c["profile"] for c in self.f.calls() if c["tool"] != "cargo"}, {"svc"})
        plan = next(c for c in self.f.calls("terraform") if "plan" in c["args"])
        self.assertIn(f"-var=deploy_commit={self.f.sha}", plan["args"])
        self.assertIn("-var-file=live.tfvars", plan["args"])
        self.assertIn("-chdir=" + str(self.f.repo / "infra/aws"), plan["args"])
        smoke_env = (self.f.stub / "smoke-env").read_text()
        self.assertIn(f"DEPLOY_COMMIT={self.f.sha}\n", smoke_env)
        self.assertIn("DEPLOY_TARGET=live\n", smoke_env)
        self.assertIn(f"DEPLOY_INFRA={self.f.repo / 'infra/aws'}\n", smoke_env)
        self.assertIn("AWS_PROFILE=svc\n", smoke_env)

    def test_zip_is_reproducible(self):
        self.assertEqual(self.f.run().returncode, 0)
        zip_path = Path(json.loads((self.f.stub / "plan-vars.json").read_text())["lambda_zip_path"])
        first = zip_path.read_bytes()
        with zipfile.ZipFile(zip_path) as z:
            (info,) = z.infolist()
            self.assertEqual(info.filename, "bootstrap")
            self.assertEqual(info.external_attr >> 16, 0o100755)
            self.assertEqual(info.date_time, (1980, 1, 1, 0, 0, 0))
            self.assertEqual(z.read("bootstrap"), b"binary svc-service\n")
        os.utime(self.f.stub / "target/x86_64-unknown-linux-musl/release/svc-service", (0, 0))
        self.assertEqual(self.f.run().returncode, 0)
        self.assertEqual(zip_path.read_bytes(), first)

    def test_honours_cargo_target_dir(self):
        target_dir = self.tmp / "elsewhere"
        self.assertEqual(self.f.run(CARGO_TARGET_DIR=str(target_dir)).returncode, 0)
        zip_path = json.loads((self.f.stub / "plan-vars.json").read_text())["lambda_zip_path"]
        self.assertTrue(zip_path.startswith(str(target_dir)), zip_path)

    def test_allowed_replace_applies(self):
        self.f.scenario["changes"] = [change("aws_lambda_permission.allowed", "delete", "create")]
        out = self.f.run()
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertTrue(self.f.applied())

    # --- each refusal -----------------------------------------------------

    def test_refuses_wrong_account(self):
        self.f.scenario["account"] = "999999999999"
        self.assertRefused(self.f.run(), "is account 999999999999, not 111122223333")
        self.assertEqual(self.f.calls("cargo") + self.f.calls("terraform"), [])

    def test_refuses_dirty_tree(self):
        self.f.write("stray.txt", "x")
        self.assertRefused(self.f.run(), "uncommitted or untracked")
        self.assertEqual(self.f.calls("cargo"), [])

    def test_refuses_commit_not_on_main(self):
        self.f.write("feature.txt", "x")
        sha = commit_all(self.f.repo, push=False)
        self.assertRefused(self.f.run(), f"{sha} is not on origin/main")
        self.assertEqual(self.f.calls("cargo"), [])

    def test_refuses_delete(self):
        self.f.scenario["changes"] = [change("aws_dynamodb_table.data", "delete")]
        self.assertRefused(self.f.run(), "aws_dynamodb_table.data (delete)")
        self.assertFalse(self.f.applied())

    def test_refuses_unlisted_replace(self):
        self.f.scenario["changes"] = [change("aws_s3_bucket.b", "create", "delete")]
        self.assertRefused(self.f.run(), "aws_s3_bucket.b (create+delete)")
        self.assertFalse(self.f.applied())

    def test_allow_replace_does_not_allow_delete(self):
        self.f.scenario["changes"] = [change("aws_lambda_permission.allowed", "delete")]
        self.assertRefused(self.f.run(), "aws_lambda_permission.allowed (delete)")
        self.assertFalse(self.f.applied())

    def test_refuses_code_not_the_built_zip(self):
        self.f.scenario["override"] = {"fn-tick": {"CodeSha256": "stale"}}
        self.assertRefused(self.f.run(), "fn-tick runs code stale, not the built zip")
        self.assertFalse((self.f.stub / "smoke-env").exists())

    def test_refuses_description_not_this_commit(self):
        self.f.scenario["override"] = {"fn-service": {"Description": "commit old"}}
        self.assertRefused(self.f.run(), "fn-service's description is 'commit old'")
        self.assertFalse((self.f.stub / "smoke-env").exists())

    def test_refuses_missing_binary(self):
        self.f.scenario["missing_bins"] = ["svc-tick"]
        self.assertRefused(self.f.run(), "cargo built no")
        self.assertEqual(self.f.calls("terraform"), [])

    def test_smoke_failure_fails_the_deploy(self):
        self.assertRefused(self.f.run(SMOKE_EXIT="3"), "scripts/smoke.sh")

    def test_unknown_target(self):
        self.assertRefused(self.f.run("prod"), "no target 'prod' (it has: live)")


SECRET = "s3cret-value-never-logged"


class HookTest(unittest.TestCase):
    """The optional plan_env and plan_check hooks (shared-terraform#12)."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="deploy-lambda-test-"))
        self.f = Fixture(self.tmp)
        self.f.scenario["log_env"] = ["PROVIDER_API_KEY", "DEPLOY_COMMIT"]

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def hooks(self, plan_env=None, plan_check=None):
        """Add the given hook scripts to the target and land them."""
        manifest = MANIFEST.format(engine=PIN)
        for field, body in (("plan_env", plan_env), ("plan_check", plan_check)):
            if body is None:
                continue
            rel = f"scripts/{field}.sh"
            self.f.write(rel, "#!/usr/bin/env bash\n" + body)
            (self.f.repo / rel).chmod(0o755)
            manifest = manifest.replace('smoke = ', f'{field} = "{rel}"\nsmoke = ')
        self.f.write(".amber/deploy.toml", manifest)
        self.f.sha = commit_all(self.f.repo)

    def assertRefused(self, out, needle):
        self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
        self.assertIn("refusing", out.stderr)
        self.assertIn(needle, out.stderr)

    # --- plan_env -----------------------------------------------------------

    def test_plan_env_reaches_terraform_only_and_is_never_logged(self):
        self.hooks(plan_env=f'echo "PROVIDER_API_KEY={SECRET}"\n'
                            'echo\necho "OTHER=a=b"\n'
                            'echo "commit $DEPLOY_COMMIT" >&2\n')
        out = self.f.run()
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        tf = self.f.calls("terraform")
        for cmd in ("init", "plan", "show", "apply"):
            call = next(c for c in tf if cmd in c["args"])
            self.assertEqual(call["env"]["PROVIDER_API_KEY"], SECRET, cmd)
        # Nothing else gets it: not aws, not cargo, not the smoke hook.
        others = [c for c in self.f.calls() if c["tool"] != "terraform"]
        self.assertTrue(others)
        self.assertTrue(all(c["env"]["PROVIDER_API_KEY"] is None for c in others))
        self.assertNotIn(SECRET, (self.f.stub / "smoke-env").read_text())
        self.assertNotIn(SECRET, out.stdout + out.stderr)
        self.assertIn("plan_env sets OTHER, PROVIDER_API_KEY for terraform", out.stdout)
        # The hook runs with the same DEPLOY_* variables as the smoke hook.
        self.assertIn(f"commit {self.f.sha}", out.stderr)

    def test_plan_env_runs_before_the_build(self):
        self.hooks(plan_env="exit 4\n")
        self.assertRefused(self.f.run(), "plan_env.sh` exited 4")
        self.assertEqual(self.f.calls("cargo") + self.f.calls("terraform"), [])

    def test_plan_env_bad_line_is_refused_unshown(self):
        self.hooks(plan_env=f'echo "PROVIDER_API_KEY={SECRET}"\necho "oops {SECRET}"\n')
        out = self.f.run()
        self.assertRefused(out, "plan_env line 2 is not KEY=value (the line is not shown)")
        self.assertNotIn(SECRET, out.stdout + out.stderr)
        self.assertEqual(self.f.calls("terraform"), [])

    def test_plan_env_may_not_set_engine_variables(self):
        for name in ("AWS_PROFILE", "TF_CLI_ARGS_apply"):
            self.hooks(plan_env=f'echo "{name}=x"\n')
            self.assertRefused(self.f.run(), f"plan_env may not set {name}")
            self.assertEqual(self.f.calls("terraform"), [])

    def test_plan_env_refuses_empty_and_duplicate(self):
        self.hooks(plan_env='echo "PROVIDER_API_KEY="\n')
        self.assertRefused(self.f.run(), "plan_env sets PROVIDER_API_KEY to an empty value")
        self.hooks(plan_env='echo "A=1"\necho "A=2"\n')
        self.assertRefused(self.f.run(), "plan_env sets A twice")

    # --- plan_check ---------------------------------------------------------

    def test_plan_check_reads_the_plan_and_accepts(self):
        self.f.scenario["changes"] = [change("aws_lambda_function.svc", "update")]
        self.hooks(plan_check='cat > "$STUB_DIR/checked.json"\n')
        out = self.f.run()
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertTrue(self.f.applied())
        checked = json.loads((self.f.stub / "checked.json").read_text())
        self.assertEqual(checked["resource_changes"], self.f.scenario["changes"])

    def test_plan_check_refusal_stops_the_apply(self):
        self.hooks(plan_check='cat >/dev/null\necho "a channel would be dropped" >&2\nexit 2\n')
        out = self.f.run()
        self.assertRefused(out, "plan_check scripts/plan_check.sh refused the plan (exit 2)")
        self.assertIn("a channel would be dropped", out.stderr)
        self.assertFalse(self.f.applied())

    def test_engine_guard_runs_before_plan_check(self):
        self.f.scenario["changes"] = [change("aws_dynamodb_table.data", "delete")]
        self.hooks(plan_check='touch "$STUB_DIR/checked"\n')
        self.assertRefused(self.f.run(), "aws_dynamodb_table.data (delete)")
        self.assertFalse((self.f.stub / "checked").exists())
        self.assertFalse(self.f.applied())

    def test_missing_or_unexecutable_hook_refuses_before_aws(self):
        self.hooks(plan_check="exit 0\n")
        (self.f.repo / "scripts/plan_check.sh").chmod(0o644)
        self.assertRefused(self.f.run(), "plan_check hook scripts/plan_check.sh is not an "
                                         "executable file")
        self.assertEqual(self.f.calls(), [])


class ManifestTest(unittest.TestCase):
    """A manifest the engine can't read strictly refuses before touching AWS."""

    def refuse(self, manifest, needle):
        tmp = Path(tempfile.mkdtemp(prefix="deploy-lambda-test-"))
        try:
            f = Fixture(tmp, manifest=manifest)
            out = f.run()
            self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
            self.assertIn(needle, out.stderr)
            self.assertEqual(f.calls(), [])
        finally:
            shutil.rmtree(tmp)

    def base(self):
        return MANIFEST.format(engine=PIN)

    def test_unknown_field(self):
        self.refuse(self.base().replace('smoke = ', 'smokey = "x"\nsmoke = '),
                    "unknown field(s) smokey")

    def test_missing_field(self):
        self.refuse(self.base().replace('smoke = "scripts/smoke.sh"\n', ""), "missing smoke")

    def test_bad_account(self):
        self.refuse(self.base().replace(ACCOUNT, "1234"), "12-digit")

    def test_bad_bin(self):
        self.refuse(self.base().replace('function_output = "tick_function_name"\n', ""),
                    "bins.svc-tick: missing function_output")

    def test_bad_engine(self):
        self.refuse(self.base().replace(PIN, "main"), "engine must be a 40-hex")


class PinTest(unittest.TestCase):
    """Any copy of the engine hands off to the manifest's pinned commit."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="deploy-lambda-test-"))
        # A stand-in shared-terraform holding this engine, landed on its main.
        self.st = self.tmp / "shared-terraform"
        init_repo(self.st, self.tmp / "shared-terraform.git")
        git(self.st, "config", "user.email", "test@example.invalid")
        (self.st / "scripts").mkdir()
        shutil.copy(ENGINE, self.st / "scripts/deploy-lambda")
        self.landed = commit_all(self.st)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def fixture(self, engine):
        root = self.tmp / "fx"
        root.mkdir()
        f = Fixture(root, engine=engine)
        f.env.pop("DEPLOY_LAMBDA_PINNED")
        f.env["DEPLOY_LAMBDA_SHARED_TERRAFORM"] = str(self.st)
        return f

    def test_hands_off_to_pinned_commit(self):
        # The invoked copy, outside any repo as in the README's
        # `<(git show ...)`, can't deploy; only the pinned commit's copy can.
        launcher = self.tmp / "launcher.py"
        source = ENGINE.read_text()
        head = "def deploy(repo, target, t):\n"
        self.assertIn(head, source)
        launcher.write_text(source.replace(
            head, head + "    raise Refusal('the invoked copy deployed')\n"))
        f = self.fixture(self.landed)
        out = f.run(engine=launcher)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn(f"engine pinned at shared-terraform {self.landed}", out.stdout)

    def test_refuses_pin_not_on_main(self):
        git(self.st, "commit", "-q", "--allow-empty", "-m", "unlanded")
        unlanded = git(self.st, "rev-parse", "HEAD")
        f = self.fixture(unlanded)
        out = f.run(engine=ENGINE)
        self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
        self.assertIn(f"engine {unlanded} is not a shared-terraform commit on origin/main",
                      out.stderr)
        self.assertEqual(f.calls(), [])


if __name__ == "__main__":
    unittest.main()

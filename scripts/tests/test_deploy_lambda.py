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
function_outputs = ["lambda_function_name", "filer_function_name"]

[live.bins.svc-tick]
zip_var = "tick_zip_path"
function_outputs = ["tick_function_name"]
"""

# A Terraform-only target (shared-terraform#13): a web hosting root, say.
WEB_TARGET = """
[web]
account = "{account}"
profile = "web"
region = "us-east-1"
infra = "web/infra/aws"
smoke = "scripts/smoke.sh"
"""

SMOKE = """\
#!/usr/bin/env bash
env | grep -E '^(DEPLOY_|AWS_PROFILE=)' | sort > "$STUB_DIR/smoke-env"
exit "${SMOKE_EXIT:-0}"
"""

FUNCTIONS = {
    # On rust-lambda-service >= v0.18.0: the alias `current` serves version 7
    # (shared-terraform#19).
    "fn-service": {"output": "lambda_function_name", "zip_var": "lambda_zip_path",
                   "alias": "7"},
    # A function not on the module: no alias, so $LATEST serves.
    "fn-tick": {"output": "tick_function_name", "zip_var": "tick_zip_path"},
    # A second function running svc-service's zip (social-graph's erasure
    # filer, shared-terraform#15).
    "fn-filer": {"output": "filer_function_name", "zip_var": "lambda_zip_path",
                 "alias": "3"},
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
        # A copy: a test may change its functions without touching the next test's.
        self.scenario = {"account": ACCOUNT, "functions": json.loads(json.dumps(FUNCTIONS))}
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

    def test_builds_bin_from_non_default_member(self):
        # chirp-auth's root package is the default; svc-tick stands in for its
        # canary member's bin (shared-terraform#17).
        self.f.scenario["member_bins"] = ["svc-tick"]
        out = self.f.run()
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        zip_path = json.loads((self.f.stub / "plan-vars.json").read_text())["tick_zip_path"]
        with zipfile.ZipFile(zip_path) as z:
            self.assertEqual(z.read("bootstrap"), b"binary svc-tick\n")

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
        self.assertRefused(self.f.run(), "fn-tick runs code stale, not svc-tick's built zip")
        self.assertFalse((self.f.stub / "smoke-env").exists())

    def test_checks_every_function_a_bin_names(self):
        out = self.f.run()
        self.assertEqual(out.returncode, 0, out.stderr)
        checked = [c["args"][c["args"].index("--function-name") + 1]
                   for c in self.f.calls("aws")
                   if "get-function-configuration" in c["args"] and "--qualifier" not in c["args"]]
        self.assertEqual(checked, ["fn-service", "fn-filer", "fn-tick"])
        self.assertIn("fn-filer runs svc-service's", out.stdout)

    def test_checks_the_version_the_alias_serves(self):
        out = self.f.run()
        self.assertEqual(out.returncode, 0, out.stderr)
        read = [(c["args"][c["args"].index("--function-name") + 1],
                 c["args"][c["args"].index("--qualifier") + 1] if "--qualifier" in c["args"]
                 else None)
                for c in self.f.calls("aws") if "get-function-configuration" in c["args"]]
        self.assertEqual(read, [("fn-service", None), ("fn-service", "7"),
                                ("fn-filer", None), ("fn-filer", "3"), ("fn-tick", None)])
        self.assertIn("served by alias current (version 7)", out.stdout)
        self.assertIn("fn-tick runs svc-tick's", out.stdout)
        self.assertIn("no alias current, so $LATEST serves", out.stdout)

    def test_refuses_alias_serving_another_zip(self):
        # $LATEST runs the new zip, but the alias still serves the previous
        # version: an alias update that failed or was skipped.
        self.f.scenario["version_override"] = {"fn-service": {"CodeSha256": "previous"}}
        self.assertRefused(self.f.run(), "fn-service's alias current (version 7) runs code "
                           "previous, not svc-service's built zip")
        self.assertFalse((self.f.stub / "smoke-env").exists())

    def test_refuses_alias_version_not_this_commit(self):
        self.f.scenario["version_override"] = {"fn-filer": {"Description": "commit old"}}
        self.assertRefused(self.f.run(), "fn-filer's alias current (version 3)'s description "
                           "is 'commit old'")

    def test_refuses_alias_on_latest(self):
        self.f.scenario["functions"]["fn-service"]["alias"] = "$LATEST"
        self.assertRefused(self.f.run(), "fn-service's alias current serves '$LATEST', "
                           "not a published version")

    def test_alias_lookup_failure_refuses(self):
        # Only "no such alias" means $LATEST serves; any other error refuses.
        self.f.scenario["alias_error"] = {"fn-tick": "An error occurred (AccessDeniedException)"}
        self.assertRefused(self.f.run(), "get-alias --function-name fn-tick")
        self.assertIn("AccessDeniedException", self.f.run().stderr)

    def test_refuses_second_function_running_another_zip(self):
        self.f.scenario["override"] = {"fn-filer": {"CodeSha256": "other"}}
        self.assertRefused(self.f.run(), "fn-filer runs code other, not svc-service's built zip")
        self.assertFalse((self.f.stub / "smoke-env").exists())

    def test_refuses_second_function_not_this_commit(self):
        self.f.scenario["override"] = {"fn-filer": {"Description": "commit old"}}
        self.assertRefused(self.f.run(), "fn-filer's description is 'commit old'")
        self.assertFalse((self.f.stub / "smoke-env").exists())

    def test_refuses_description_not_this_commit(self):
        self.f.scenario["override"] = {"fn-service": {"Description": "commit old"}}
        self.assertRefused(self.f.run(), "fn-service's description is 'commit old'")
        self.assertFalse((self.f.stub / "smoke-env").exists())

    def test_refuses_missing_binary(self):
        self.f.scenario["missing_bins"] = ["svc-tick"]
        self.assertRefused(self.f.run(), "cargo built no")
        self.assertEqual(self.f.calls("terraform"), [])

    def test_missing_smoke_hook_refuses_before_aws(self):
        (self.f.repo / "scripts/smoke.sh").unlink()
        commit_all(self.f.repo)
        self.assertRefused(self.f.run(), "smoke hook scripts/smoke.sh is not an executable file")
        self.assertEqual(self.f.calls(), [])

    def test_smoke_failure_fails_the_deploy(self):
        self.assertRefused(self.f.run(SMOKE_EXIT="3"), "scripts/smoke.sh")

    def test_unknown_target(self):
        self.assertRefused(self.f.run("prod"), "no target 'prod' (it has: live)")


SECRET = "s3cret-value-never-logged"


class TerraformOnlyTest(unittest.TestCase):
    """A target with no bins: everything but the build and the function checks."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="deploy-lambda-test-"))
        self.f = Fixture(self.tmp, manifest=MANIFEST.format(engine=PIN)
                         + WEB_TARGET.format(account=ACCOUNT))
        self.f.write("web/infra/aws/backend.hcl", "")
        self.f.sha = commit_all(self.f.repo)
        self.f.scenario["functions"] = {}

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def assertRefused(self, out, needle):
        self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
        self.assertIn("refusing", out.stderr)
        self.assertIn(needle, out.stderr)

    def test_deploys_without_building(self):
        self.f.scenario["changes"] = [change("aws_s3_bucket.site", "update")]
        out = self.f.run("web")
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("web has no bins: Terraform only, nothing to build", out.stdout)
        self.assertIn(f"{self.f.sha} is live on web", out.stdout)
        self.assertEqual(self.f.calls("cargo"), [])
        # The only aws call is the account check: no function to look at.
        self.assertEqual([c["args"][:2] for c in self.f.calls("aws")],
                         [["sts", "get-caller-identity"]])
        self.assertEqual({c["profile"] for c in self.f.calls()}, {"web"})
        tf = [next(a for a in c["args"] if not a.startswith("-"))
              for c in self.f.calls("terraform")]
        self.assertEqual(tf, ["init", "plan", "show", "apply"])
        plan = next(c for c in self.f.calls("terraform") if "plan" in c["args"])
        self.assertIn(f"-var=deploy_commit={self.f.sha}", plan["args"])
        self.assertIn("-chdir=" + str(self.f.repo / "web/infra/aws"), plan["args"])
        self.assertEqual([a for a in plan["args"] if a.startswith("-var")],
                         [f"-var=deploy_commit={self.f.sha}"])
        smoke_env = (self.f.stub / "smoke-env").read_text()
        self.assertIn("DEPLOY_TARGET=web\n", smoke_env)
        self.assertIn(f"DEPLOY_INFRA={self.f.repo / 'web/infra/aws'}\n", smoke_env)

    def test_keeps_the_delete_guard(self):
        self.f.scenario["changes"] = [change("aws_cloudfront_distribution.site", "delete")]
        self.assertRefused(self.f.run("web"), "aws_cloudfront_distribution.site (delete)")
        self.assertFalse(self.f.applied())

    def test_keeps_the_account_and_tree_checks(self):
        self.f.scenario["account"] = "999999999999"
        self.assertRefused(self.f.run("web"), "is account 999999999999, not 111122223333")
        self.assertEqual(self.f.calls("terraform"), [])
        self.f.scenario["account"] = ACCOUNT
        self.f.write("stray.txt", "x")
        self.assertRefused(self.f.run("web"), "uncommitted or untracked")
        self.assertEqual(self.f.calls("terraform"), [])

    def test_smoke_failure_fails_the_deploy(self):
        self.assertRefused(self.f.run("web", SMOKE_EXIT="3"), "scripts/smoke.sh")


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


# A prebuild that builds a site into an ignored dir, and logs that it ran (in
# order with the stubs' calls) with its DEPLOY_* variables.
PREBUILD = """\
#!/usr/bin/env bash
set -e
printf '{"tool": "prebuild", "args": [], "profile": "%s", "env": {"DEPLOY_COMMIT": "%s"}}\\n' \\
  "$AWS_PROFILE" "$DEPLOY_COMMIT" >> "$STUB_DIR/calls.log"
rm -rf site/public
mkdir -p site/public/assets
echo '<html>' > site/public/index.html
echo 'js' > site/public/assets/app.js
chmod 755 site/public/assets/app.js
echo '{}' > site/public/app-config.json
"""


class IncludeTest(unittest.TestCase):
    """The prebuild hook and a bin's include (shared-terraform#14)."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="deploy-lambda-test-"))
        self.f = Fixture(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def setup(self, prebuild=PREBUILD, include='{ "frontend/public" = "site/public" }'):
        manifest = MANIFEST.format(engine=PIN)
        if prebuild is not None:
            self.f.write("scripts/prebuild.sh", prebuild)
            (self.f.repo / "scripts/prebuild.sh").chmod(0o755)
            manifest = manifest.replace('smoke = ', 'prebuild = "scripts/prebuild.sh"\nsmoke = ')
        if include is not None:
            line = 'function_outputs = ["lambda_function_name", "filer_function_name"]\n'
            manifest = manifest.replace(line, line + f'include = {include}\n')
        self.f.write(".amber/deploy.toml", manifest)
        self.f.write(".gitignore", "site/public/\n")
        self.f.sha = commit_all(self.f.repo)

    def zip_of(self, var):
        return Path(json.loads((self.f.stub / "plan-vars.json").read_text())[var])

    def assertRefused(self, out, needle):
        self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
        self.assertIn("refusing", out.stderr)
        self.assertIn(needle, out.stderr)

    def test_prebuild_runs_then_include_ships_beside_bootstrap(self):
        self.setup()
        out = self.f.run()
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        tools = [c["tool"] for c in self.f.calls()]
        self.assertEqual(tools[:3], ["aws", "prebuild", "cargo"])
        pre = next(c for c in self.f.calls() if c["tool"] == "prebuild")
        self.assertEqual(pre["profile"], "svc")
        self.assertEqual(pre["env"]["DEPLOY_COMMIT"], self.f.sha)
        self.assertIn("(+3 included file(s))", out.stdout)
        with zipfile.ZipFile(self.zip_of("lambda_zip_path")) as z:
            infos = z.infolist()
            self.assertEqual([i.filename for i in infos],
                             ["bootstrap", "frontend/public/app-config.json",
                              "frontend/public/assets/app.js", "frontend/public/index.html"])
            self.assertEqual(infos[0].external_attr >> 16, 0o100755)
            # Every included file is 0644, whatever its mode on disk.
            self.assertEqual({i.external_attr >> 16 for i in infos[1:]}, {0o100644})
            self.assertEqual({i.date_time for i in infos}, {(1980, 1, 1, 0, 0, 0)})
            self.assertEqual(z.read("frontend/public/index.html"), b"<html>\n")
        # A bin with no include still zips bootstrap alone.
        with zipfile.ZipFile(self.zip_of("tick_zip_path")) as z:
            self.assertEqual(z.namelist(), ["bootstrap"])

    def test_zip_with_include_is_reproducible(self):
        self.setup()
        self.assertEqual(self.f.run().returncode, 0)
        first = self.zip_of("lambda_zip_path").read_bytes()
        # The prebuild rewrites every file, with new mtimes, on each run.
        self.assertEqual(self.f.run().returncode, 0)
        self.assertEqual(self.zip_of("lambda_zip_path").read_bytes(), first)

    def test_include_without_prebuild(self):
        self.setup(prebuild=None, include='{ "static" = "assets" }')
        self.f.write("assets/a.txt", "a")
        self.f.sha = commit_all(self.f.repo)
        out = self.f.run()
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        with zipfile.ZipFile(self.zip_of("lambda_zip_path")) as z:
            self.assertEqual(z.namelist(), ["bootstrap", "static/a.txt"])

    def test_prebuild_failure_refuses_before_the_build(self):
        self.setup(prebuild="#!/usr/bin/env bash\nexit 5\n")
        self.assertRefused(self.f.run(), "prebuild.sh` exited 5")
        self.assertEqual(self.f.calls("cargo") + self.f.calls("terraform"), [])

    def test_prebuild_may_not_dirty_the_tree(self):
        self.setup(prebuild=PREBUILD + "echo x > not-ignored.txt\n")
        self.assertRefused(self.f.run(), "after prebuild scripts/prebuild.sh, the checkout "
                                         "has uncommitted or untracked changes")
        self.assertEqual(self.f.calls("cargo") + self.f.calls("terraform"), [])

    def test_missing_include_dir_refuses_before_terraform(self):
        self.setup(prebuild=None)
        self.assertRefused(self.f.run(), "bins.svc-service.include: site/public is not a "
                                         "directory")
        self.assertEqual(self.f.calls("terraform"), [])

    def test_empty_include_dir_refuses(self):
        self.setup(prebuild="#!/usr/bin/env bash\nmkdir -p site/public/empty\n")
        self.assertRefused(self.f.run(), "site/public has no files")
        self.assertEqual(self.f.calls("terraform"), [])

    def test_symlink_in_include_refuses(self):
        self.setup(prebuild=PREBUILD + "ln -s /etc/passwd site/public/leak\n")
        self.assertRefused(self.f.run(), "site/public/leak is not a regular file or directory")
        self.assertEqual(self.f.calls("terraform"), [])

    def test_unexecutable_prebuild_refuses_before_aws(self):
        self.setup()
        (self.f.repo / "scripts/prebuild.sh").chmod(0o644)
        self.assertRefused(self.f.run(), "prebuild hook scripts/prebuild.sh is not an "
                                         "executable file")
        self.assertEqual(self.f.calls(), [])


class ManifestTest(unittest.TestCase):
    """A manifest the engine can't read strictly refuses before touching AWS."""

    def refuse(self, manifest, needle, target="live"):
        tmp = Path(tempfile.mkdtemp(prefix="deploy-lambda-test-"))
        try:
            f = Fixture(tmp, manifest=manifest)
            out = f.run(target)
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
        self.refuse(self.base().replace('function_outputs = ["tick_function_name"]\n', ""),
                    "bins.svc-tick: missing function_outputs")

    def test_function_outputs_must_list_names(self):
        tick = 'function_outputs = ["tick_function_name"]'
        for value in ('"tick_function_name"', '[""]', '[3]'):
            self.refuse(self.base().replace(tick, f"function_outputs = {value}"),
                        "bins.svc-tick: function_outputs must")

    def test_function_outputs_may_not_be_empty(self):
        self.refuse(self.base().replace('["tick_function_name"]', "[]"),
                    "bins.svc-tick: function_outputs must be a non-empty")

    def test_old_function_output_names_the_new_field(self):
        self.refuse(self.base().replace('function_outputs = ["tick_function_name"]',
                                        'function_output = "tick_function_name"'),
                    "bins.svc-tick: function_output is now function_outputs, a list")

    def test_function_listed_twice_is_refused(self):
        tick = '["tick_function_name"]'
        # Under one bin, or under two (one function checked against two zips).
        self.refuse(self.base().replace(tick, '["tick_function_name", "tick_function_name"]'),
                    "lists tick_function_name more than once")
        self.refuse(self.base().replace(tick, '["tick_function_name", "filer_function_name"]'),
                    "lists filer_function_name more than once")

    def test_empty_bins(self):
        self.refuse(self.base() + WEB_TARGET.format(account=ACCOUNT)
                    + 'cargo_manifest = "Cargo.toml"\nbins = {}\n',
                    "[web]: bins is empty (omit bins and cargo_manifest", "web")

    def test_cargo_manifest_without_bins(self):
        self.refuse(self.base() + WEB_TARGET.format(account=ACCOUNT)
                    + 'cargo_manifest = "Cargo.toml"\n',
                    "[web]: bins and cargo_manifest go together", "web")

    def test_bins_without_cargo_manifest(self):
        self.refuse(self.base().replace('cargo_manifest = "Cargo.toml"\n', ""),
                    "[live]: bins and cargo_manifest go together")

    def include(self, value):
        return self.base().replace('function_outputs = ["tick_function_name"]\n',
                                   'function_outputs = ["tick_function_name"]\n'
                                   f'include = {value}\n')

    def test_include_may_not_name_bootstrap(self):
        for zip_dir in ("bootstrap", "bootstrap/x"):
            self.refuse(self.include(f'{{ "{zip_dir}" = "web" }}'),
                        f"zip path '{zip_dir}' would collide with bootstrap")

    def test_include_paths_are_plain_relative(self):
        for value in ('{ "/abs" = "web" }', '{ "a/../b" = "web" }', '{ "a/" = "web" }'):
            self.refuse(self.include(value), "must be relative")
        for value in ('{ "a" = "../outside" }', '{ "a" = "/etc" }', '{ "a" = "." }',
                      '{ "a" = 3 }'):
            self.refuse(self.include(value), "must name a repo-relative dir")

    def test_include_paths_may_not_nest(self):
        self.refuse(self.include('{ "a" = "x", "a/b" = "y" }'), "zip path 'a/b' is inside 'a'")

    def test_include_must_be_a_table(self):
        self.refuse(self.include('"web"'), "include must be a non-empty dict")

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

    def test_hands_off_an_old_schema_manifest(self):
        # shared-terraform#16: a manifest pinned before a schema change (here
        # #15's function_output) is the pinned engine's to read. The invoked
        # copy hands off instead of refusing it under its own, newer schema.
        (self.st / "scripts/deploy-lambda").write_text(
            "import sys\nprint('old engine ran', sys.argv[1:])\n")
        old = commit_all(self.st)
        f = self.fixture(old)
        f.write(".amber/deploy.toml", MANIFEST.format(engine=old).replace(
            'function_outputs = ["tick_function_name"]',
            'function_output = "tick_function_name"'))
        commit_all(f.repo)
        out = f.run(engine=ENGINE)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn(f"engine pinned at shared-terraform {old}", out.stdout)
        self.assertIn("old engine ran ['live']", out.stdout)

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

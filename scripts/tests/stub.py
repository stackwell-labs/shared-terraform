#!/usr/bin/env python3
"""A fake aws, terraform and cargo for test_deploy_lambda.py.

Installed under each of those names; it acts by the name it was called as and
by $STUB_DIR/scenario.json, and logs every call to $STUB_DIR/calls.log (with
the variables the scenario's log_env names).
"""

import base64
import hashlib
import json
import os
import sys
from pathlib import Path

state = Path(os.environ["STUB_DIR"])
scenario = json.loads((state / "scenario.json").read_text())
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with (state / "calls.log").open("a") as log:
    log.write(json.dumps({"tool": tool, "args": args,
                          "profile": os.environ.get("AWS_PROFILE"),
                          "env": {k: os.environ.get(k) for k in scenario.get("log_env", [])}})
              + "\n")


def deployed():
    p = state / "deployed.json"
    return json.loads(p.read_text()) if p.exists() else {}


def published(fn, f):
    """fn's published versions, oldest first, less those deleted: by default
    1 to its alias's version, one per apply (shared-terraform#20)."""
    gone = json.loads((state / "deleted.json").read_text()) if (state / "deleted.json").exists() else []
    versions = f.get("versions", [str(v) for v in range(1, int(f.get("alias", 0)) + 1)])
    return [v for v in versions if [fn, v] not in gone]


def opt(name):
    return next((a.split("=", 1)[1] for a in args if a.startswith(name + "=")), None)


if tool == "aws":
    if args[:2] == ["sts", "get-caller-identity"]:
        print(scenario["account"])
    elif "wait" in args:
        pass
    elif "get-alias" in args:
        # A function on rust-lambda-service >= v0.18.0 has the alias
        # `current` on the version each apply publishes (shared-terraform#19).
        fn = args[args.index("--function-name") + 1]
        f = scenario["functions"][fn]
        if fn in scenario.get("alias_error", {}):
            sys.exit(scenario["alias_error"][fn])
        if not f.get("alias") or args[args.index("--name") + 1] != "current":
            print("An error occurred (ResourceNotFoundException) when calling the "
                  f"GetAlias operation: Alias not found: {fn}:current", file=sys.stderr)
            sys.exit(254)
        print(json.dumps({"Name": "current", "FunctionVersion": f["alias"]}))
    elif "get-function-configuration" in args:
        fn = args[args.index("--function-name") + 1]
        f = scenario["functions"][fn]
        cfg = dict(deployed()[f["zip_var"]])
        if "--qualifier" in args:
            # The alias's version: published by the apply, so it runs what
            # $LATEST ran then, unless the scenario says the alias serves
            # another one.
            if args[args.index("--qualifier") + 1] != f.get("alias"):
                print("An error occurred (ResourceNotFoundException) when calling the "
                      "GetFunctionConfiguration operation: Function not found",
                      file=sys.stderr)
                sys.exit(254)
            cfg.update(scenario.get("version_override", {}).get(fn, {}))
        else:
            cfg.update(scenario.get("override", {}).get(fn, {}))
        print(json.dumps(cfg))
    elif "list-versions-by-function" in args:
        fn = args[args.index("--function-name") + 1]
        versions = ["$LATEST"] + published(fn, scenario["functions"][fn])
        print(json.dumps({"Versions": [{"Version": v} for v in versions]}))
    elif "list-aliases" in args:
        fn = args[args.index("--function-name") + 1]
        f = scenario["functions"][fn]
        aliases = [{"Name": "current", "FunctionVersion": f["alias"]}] + f.get("aliases", [])
        print(json.dumps({"Aliases": aliases}))
    elif "delete-function" in args:
        fn = args[args.index("--function-name") + 1]
        version = args[args.index("--qualifier") + 1]
        if version in scenario.get("delete_error", {}).get(fn, []):
            print("An error occurred (ResourceConflictException) when calling the "
                  "DeleteFunction operation", file=sys.stderr)
            sys.exit(254)
        if version not in published(fn, scenario["functions"][fn]):
            sys.exit(f"stub aws: no version {version} of {fn} to delete")
        p = state / "deleted.json"
        gone = json.loads(p.read_text()) if p.exists() else []
        p.write_text(json.dumps(gone + [[fn, version]]))
    elif args[:2] == ["events", "put-events"]:
        # The probes-deploys bus (shared-terraform#21): it takes the event
        # unless the scenario says how it answers instead.
        if "put_events_exit" in scenario:
            print("An error occurred (AccessDeniedException) when calling the "
                  "PutEvents operation", file=sys.stderr)
            sys.exit(scenario["put_events_exit"])
        print(json.dumps(scenario.get("put_events",
                                      {"FailedEntryCount": 0, "Entries": [{"EventId": "evt-1"}]})))
    else:
        sys.exit(f"stub aws: unexpected {args}")

elif tool == "terraform":
    cmd = next(a for a in args if not a.startswith("-"))
    if cmd == "init":
        pass
    elif cmd == "plan":
        Path(opt("-out")).write_text("plan")
        vars_ = dict(a[len("-var="):].split("=", 1) for a in args if a.startswith("-var="))
        (state / "plan-vars.json").write_text(json.dumps(vars_))
    elif cmd == "show":
        print(json.dumps({"resource_changes": scenario.get("changes", [])}))
    elif cmd == "apply":
        vars_ = json.loads((state / "plan-vars.json").read_text())
        out = {}
        for fn, f in scenario["functions"].items():
            digest = hashlib.sha256(Path(vars_[f["zip_var"]]).read_bytes()).digest()
            out[f["zip_var"]] = {"CodeSha256": base64.b64encode(digest).decode(),
                                 "Description": f"commit {vars_['deploy_commit']}"}
        (state / "deployed.json").write_text(json.dumps(out))
    elif cmd == "output":
        name = args[-1]
        print(next(fn for fn, f in scenario["functions"].items() if f["output"] == name), end="")
    else:
        sys.exit(f"stub terraform: unexpected {args}")

elif tool == "cargo":
    target_dir = Path(os.environ.get("CARGO_TARGET_DIR") or state / "target")
    if args[0] == "metadata":
        print(json.dumps({"target_directory": str(target_dir)}))
    elif args[0] == "build":
        release = target_dir / "x86_64-unknown-linux-musl" / "release"
        release.mkdir(parents=True, exist_ok=True)
        bins = [args[i + 1] for i, a in enumerate(args) if a == "--bin"]
        # Bins a non-default workspace member owns: like real cargo, found
        # only with --workspace (shared-terraform#17).
        for b in scenario.get("member_bins", []):
            if b in bins and "--workspace" not in args:
                sys.exit(f"error: no bin target named `{b}` in default-run packages")
        for b in bins:
            if b not in scenario.get("missing_bins", []):
                (release / b).write_bytes(f"binary {b}\n".encode())
    else:
        sys.exit(f"stub cargo: unexpected {args}")

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


def opt(name):
    return next((a.split("=", 1)[1] for a in args if a.startswith(name + "=")), None)


if tool == "aws":
    if args[:2] == ["sts", "get-caller-identity"]:
        print(scenario["account"])
    elif "wait" in args:
        pass
    elif "get-function-configuration" in args:
        fn = args[args.index("--function-name") + 1]
        zip_var = scenario["functions"][fn]["zip_var"]
        cfg = dict(deployed()[zip_var])
        cfg.update(scenario.get("override", {}).get(fn, {}))
        print(json.dumps(cfg))
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
        for b in bins:
            if b not in scenario.get("missing_bins", []):
                (release / b).write_bytes(f"binary {b}\n".encode())
    else:
        sys.exit(f"stub cargo: unexpected {args}")

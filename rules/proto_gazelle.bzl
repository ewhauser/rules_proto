# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""proto_gazelle.bzl provides the proto_gazelle rule.
"""

load(
    "@bazel_skylib//lib:shell.bzl",
    "shell",
)

load(
    "@bazel_gazelle_is_bazel_module//:defs.bzl",
    "GAZELLE_IS_BAZEL_MODULE",
)


DEFAULT_LANGUAGES = [
    "@bazel_gazelle//language/proto:go_default_library",
    "@bazel_gazelle//language/go:go_default_library",
    "@build_stack_rules_proto//language/protobuf",
]

def _valid_env_variable_name(name):
    """ Returns if a string is in the regex [a-zA-Z_][a-zA-Z0-9_]*

    Given that bazel lacks support of regex, we need to implement
    a poor man validation
    """
    if not name:
        return False
    for i, c in enumerate(name.elems()):
        if c.isalpha() or c == "_" or (i > 0 and c.isdigit()):
            continue
        return False
    return True

def _rlocation_path(ctx, file):
    if file.short_path.startswith("../"):
        return file.short_path[3:]
    else:
        return ctx.workspace_name + "/" + file.short_path

def _gazelle_runner_impl(ctx):
    args = [ctx.attr.command]
    if ctx.attr.mode:
        args.extend(["-mode", ctx.attr.mode])
    if ctx.attr.external:
        args.extend(["-external", ctx.attr.external])
    if ctx.attr.prefix:
        args.extend(["-go_prefix", ctx.attr.prefix])
    if ctx.attr.build_tags:
        args.extend(["-build_tags", ",".join(ctx.attr.build_tags)])
    if GAZELLE_IS_BAZEL_MODULE:
        args.append("-bzlmod")
    if ctx.attr.cfgs:
        cfgs = ",".join([f.short_path for f in ctx.files.cfgs])
        args.extend(["-proto_configs", cfgs])
    if ctx.attr.imports:
        imports = ",".join([f.short_path for f in ctx.files.imports])
        args.extend(["-proto_imports_in", imports])

    args.extend([ctx.expand_location(arg, ctx.attr.data) for arg in ctx.attr.extra_args])

    for key in ctx.attr.env:
        if not _valid_env_variable_name(key):
            fail("Invalid environmental variable name: '%s'" % key)

    env = "\n".join(["export %s=%s" % (x, shell.quote(y)) for (x, y) in ctx.attr.env.items()])

    out_file = ctx.actions.declare_file(ctx.label.name + ".bash")
    go_tool = ctx.toolchains["@io_bazel_rules_go//go:toolchain"].sdk.go
    repo_config = ctx.file._repo_config
    substitutions = {
        "@@ARGS@@": shell.array_literal(args),
        "@@GAZELLE_PATH@@": shell.quote(_rlocation_path(ctx, ctx.executable.gazelle)),
        "@@GENERATED_MESSAGE@@": """
# Generated by {label}
# DO NOT EDIT
""".format(label = str(ctx.label)),
        "@@GOTOOL@@": shell.quote(_rlocation_path(ctx, go_tool)),
        "@@ENV@@": env,
        "@@REPO_CONFIG_PATH@@": shell.quote(_rlocation_path(ctx, repo_config)) if repo_config else "",
    }
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = out_file,
        substitutions = substitutions,
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = ctx.files.cfgs + ctx.files.imports + [
        ctx.executable.gazelle,
        go_tool,
    ] + ([repo_config] if repo_config else [])).merge(
        ctx.attr.gazelle[DefaultInfo].default_runfiles,
    )
    for d in ctx.attr.data:
        runfiles = runfiles.merge(d[DefaultInfo].default_runfiles)
    return [DefaultInfo(
        files = depset([out_file]),
        runfiles = runfiles,
        executable = out_file,
    )]

_gazelle_runner = rule(
    implementation = _gazelle_runner_impl,
    attrs = {
        "gazelle": attr.label(
            default = "@build_stack_rules_proto//cmd/gazelle",
            executable = True,
            cfg = "exec",
        ),
        "command": attr.string(
            values = [
                "fix",
                "update",
                "update-repos",
            ],
            default = "update",
        ),
        "mode": attr.string(
            values = ["", "print", "fix", "diff"],
            default = "",
        ),
        "external": attr.string(
            values = ["", "external", "static", "vendored"],
            default = "",
        ),
        "build_tags": attr.string_list(),
        "prefix": attr.string(),
        "extra_args": attr.string_list(),
        "data": attr.label_list(allow_files = True),
        "imports": attr.label_list(allow_files = True),
        "cfgs": attr.label_list(allow_files = True),
        "env": attr.string_dict(),
        "_repo_config": attr.label(
            default = "@bazel_gazelle_go_repository_config//:WORKSPACE" if GAZELLE_IS_BAZEL_MODULE else None,
            allow_single_file = True,
        ),
        "_template": attr.label(
            default = "@bazel_gazelle//internal:gazelle.bash.in",
            allow_single_file = True,
        ),
    },
    executable = True,
    toolchains = ["@io_bazel_rules_go//go:toolchain"],
)

def proto_gazelle(name, **kwargs):
    """proto_gazelle is the macro that calls the gazelle runner

    Args:
        name: the name of the rule
        **kwargs: arguments to gazelle_runner
    """
    if "args" in kwargs:
        # The args attribute has special meaning for executable rules, but we
        # always want extra_args here instead.
        if "extra_args" in kwargs:
            fail("{}: both args and extra_args were provided".format(name))
        kwargs["extra_args"] = kwargs["args"]
        kwargs.pop("args")

    visibility = kwargs.pop("visibility", default = None)

    tags_set = {t: "" for t in kwargs.pop("tags", [])}
    tags_set["manual"] = ""
    tags = [k for k in tags_set.keys()]
    runner_name = name + "-runner"
    _gazelle_runner(
        name = runner_name,
        tags = tags,
        **kwargs
    )
    native.sh_binary(
        name = name,
        srcs = [runner_name],
        tags = tags,
        visibility = visibility,
        deps = ["@bazel_tools//tools/bash/runfiles"],
        data = kwargs["data"] if "data" in kwargs else [],
    )

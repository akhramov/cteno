"""
zig fmt rule.
Taken from https://github.com/aerolang/aero/blob/2b0d8da0f2f2d6792374dad8fc67e6aa17c03281/bazel/tools/format/zig_fmt.bzl MIT License
"""

def _zig_fmt_impl(ctx):
    info = ctx.toolchains["@rules_zig//zig:toolchain_type"].zigtoolchaininfo
    zig_exe = info.zig_exe.file
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = out, target_file = zig_exe, is_executable = True)
    return [DefaultInfo(executable = out, runfiles = ctx.runfiles(files = [info.zig_exe.file]))]

zig_fmt = rule(
    implementation = _zig_fmt_impl,
    executable = True,
    toolchains = ["@rules_zig//zig:toolchain_type"],
)

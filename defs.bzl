load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_zig//zig:defs.bzl", "zig_c_library")

def _headers_import(version):
    c_library_name = "{}_private".format(version)

    cc_library(
        name = c_library_name,
        hdrs = ["src/python/header.h"],
        deps = ["@python_%s//:python_headers" % version],
        includes = ["src/python_version"],
    )

    zig_c_library(
        name = version,
        cdeps = [c_library_name],
    )

def import_python_headers(versions):
    [_headers_import(version) for version in versions]

    return [":{}".format(version) for version in versions]

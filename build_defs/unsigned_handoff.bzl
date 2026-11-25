"""Declare the configured unsigned application's external-signer inputs."""
load("@rules_apple//apple:providers.bzl", "AppleBundleInfo")

def _record(file):
    return {"path": file.path, "directory": file.is_directory}

def _unsigned_handoff_impl(ctx):
    product = ctx.attr.product
    archive = product[AppleBundleInfo].archive
    groups = product[OutputGroupInfo]
    dsyms = groups.dsyms
    linkmaps = groups.linkmaps if hasattr(groups, "linkmaps") else depset()
    manifest = ctx.actions.declare_file(ctx.label.name + ".unsigned-handoff.json")
    ctx.actions.write(manifest, json.encode({
        "schema_version": 1,
        "product": str(product.label),
        "archive": _record(archive),
        "dsyms": [_record(file) for file in dsyms.to_list()],
        "linkmaps": [_record(file) for file in linkmaps.to_list()],
        "generate_appcast": _record(ctx.file.generate_appcast),
    }) + "\n")
    files = depset([manifest, archive, ctx.file.generate_appcast], transitive = [dsyms, linkmaps])
    return [DefaultInfo(files = files), OutputGroupInfo(unsigned_handoff = files)]

unsigned_handoff = rule(
    implementation = _unsigned_handoff_impl,
    attrs = {
        "product": attr.label(mandatory = True, providers = [AppleBundleInfo, OutputGroupInfo]),
        "generate_appcast": attr.label(
            default = "@swiftpkg_sparkle//:remote/archive/Sparkle-for-Swift-Package-Manager.zip/bin/generate_appcast",
            allow_single_file = True,
        ),
    },
)

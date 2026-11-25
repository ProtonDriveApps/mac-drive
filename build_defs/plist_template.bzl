"""Expand Xcode placeholders without modifying the original plist."""

def _plist_template_impl(ctx):
    # Like filling blanks in a form: Bazel owns the filled-in copy.
    output = ctx.actions.declare_file(ctx.label.name + ".plist")
    if ctx.file.version_file:
        substitutions = ctx.actions.declare_file(ctx.label.name + ".substitutions.json")
        ctx.actions.write(substitutions, json.encode(ctx.attr.substitutions))
        ctx.actions.run(
            executable = ctx.executable._release_version,
            arguments = [
                "--version-file", ctx.file.version_file.path,
                "--template", ctx.file.src.path,
                "--substitutions", substitutions.path,
                "--output", output.path,
            ],
            inputs = [ctx.file.src, ctx.file.version_file, substitutions],
            outputs = [output],
            mnemonic = "VersionedPlist",
        )
    else:
        ctx.actions.expand_template(
            template = ctx.file.src,
            output = output,
            substitutions = ctx.attr.substitutions,
        )
    return [DefaultInfo(files = depset([output]))]

plist_template = rule(
    implementation = _plist_template_impl,
    attrs = {
        "src": attr.label(allow_single_file = True, mandatory = True),
        "substitutions": attr.string_dict(mandatory = True),
        "version_file": attr.label(allow_single_file = True),
        "_release_version": attr.label(default = "//tools:release_version", executable = True, cfg = "exec"),
    },
)

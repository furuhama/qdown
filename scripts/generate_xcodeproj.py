#!/usr/bin/env python3
"""Generate Qdown.xcodeproj/project.pbxproj deterministically.

The project is intentionally small and explicit (no XcodeGen/Tuist dependency).
Run from the repository root.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Qdown.xcodeproj"
PROJECT.mkdir(exist_ok=True)

_id = 0
def oid():
    global _id
    _id += 1
    return f"A1{_id:022X}"

objects = []
def add(text):
    objects.append(text)
    return text

def build_file(file_ref, name):
    i = oid()
    add(f'\t\t{i} = {{isa = PBXBuildFile; fileRef = {file_ref}; }}; /* {name} in Sources/Resources */')
    return i

def file_ref(path, name, file_type, source_tree='"<group>"'):
    i = oid()
    add(f'\t\t{i} = {{isa = PBXFileReference; lastKnownFileType = {file_type}; path = "{path}"; name = "{name}"; sourceTree = {source_tree}; }};')
    return i

def folder_ref(path, name):
    i = oid()
    add(f'\t\t{i} = {{isa = PBXFileReference; lastKnownFileType = folder; path = "{path}"; name = "{name}"; sourceTree = "<group>"; }};')
    return i

def group(children, name, path=None):
    i = oid()
    child_lines = "\n".join(f"\t\t\t\t{c} /* child */," for c in children)
    path_line = f'\n\t\t\tpath = "{path}";' if path else ""
    add(f'''\t\t{i} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{child_lines}
\t\t\t);
\t\t\tname = "{name}";{path_line}
\t\t\tsourceTree = "<group>";
\t\t}};''')
    return i

sources = [
    "main.swift",
    "AppDelegate.swift",
    "Document.swift",
    "DocumentWindowController.swift",
    "MarkdownWebView.swift",
    "LocalSchemeHandler.swift",
    "FindBarView.swift",
    "LinkRouter.swift",
    "ZoomStore.swift",
    "RenderTestRunner.swift",
    "DocumentOpenCoordinator.swift",
    "DocumentFileWatcher.swift",
    "SessionStore.swift",
    "DocumentController.swift",
]

source_refs = {}
for name in sources:
    source_refs[name] = file_ref(name, name, "sourcecode.swift")

source_build = [build_file(source_refs[n], n) for n in sources]

info_ref = file_ref("Info.plist", "Info.plist", "text.plist.xml")
css_ref = file_ref("quiet-light.css", "quiet-light.css", "text.css")
html_ref = file_ref("viewer.html", "viewer.html", "text.html")
viewer_css_ref = file_ref("viewer.css", "viewer.css", "text.css")
viewer_js_ref = file_ref("viewer.js", "viewer.js", "sourcecode.javascript")
vendor_ref = folder_ref("vendor", "vendor")
icon_ref = file_ref("AppIcon.icns", "AppIcon.icns", "image.icns")

resource_refs = [css_ref, html_ref, viewer_css_ref, viewer_js_ref, icon_ref, vendor_ref]
resource_build = [build_file(r, "resource") for r in resource_refs]

test_md_ref = file_ref("test.md", "test.md", "net.daringfireball.markdown")
tests_ref = folder_ref("Tests", "Tests")
readme_ref = file_ref("README.md", "README.md", "net.daringfireball.markdown")
scripts_ref = folder_ref("scripts", "scripts")

sources_group = group(list(source_refs.values()), "Sources", "Sources")
resources_group = group(resource_refs, "Resources", "Resources")
qdown_group = group([info_ref, sources_group, resources_group], "Qdown", "Qdown")

app_ref = oid()
add(f'\t\t{app_ref} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Qdown.app; sourceTree = BUILT_PRODUCTS_DIR; }}; /* Qdown.app */')
products_group = group([app_ref], "Products")

main_group = group([qdown_group, tests_ref, scripts_ref, test_md_ref, readme_ref, products_group], "Qdown")

sources_phase = oid()
add(f'''\t\t{sources_phase} = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{chr(10).join(f"\t\t\t\t{b} /* build */," for b in source_build)}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''')

frameworks_phase = oid()
add(f'''\t\t{frameworks_phase} = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''')

resources_phase = oid()
add(f'''\t\t{resources_phase} = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{chr(10).join(f"\t\t\t\t{b} /* build */," for b in resource_build)}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''')

target = oid()
product_name = "Qdown"
add(f'''\t\t{target} = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {{TARGET_CONFIG_LIST}};
\t\t\tbuildPhases = (
\t\t\t\t{sources_phase} /* Sources */,
\t\t\t\t{frameworks_phase} /* Frameworks */,
\t\t\t\t{resources_phase} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = {product_name};
\t\t\tproductName = {product_name};
\t\t\tproductReference = {app_ref} /* Qdown.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};''')

project = oid()
add(f'''\t\t{project} = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 2600;
\t\t\t\tLastUpgradeCheck = 2600;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{target} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {{PROJECT_CONFIG_LIST}};
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {main_group};
\t\t\tproductRefGroup = {products_group};
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{target} /* Qdown */,
\t\t\t);
\t\t}};''')

def build_config(name, settings):
    i = oid()
    lines = "\n".join(f"\t\t\t\t{k} = {v};" for k, v in settings.items())
    add(f'''\t\t{i} = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{lines}
\t\t\t}};
\t\t\tname = {name};
\t\t}};''')
    return i

common_project = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "COPY_PHASE_STRIP": "NO",
    "MACOSX_DEPLOYMENT_TARGET": "13.0",
    "ONLY_ACTIVE_ARCH": "NO",
    "SDKROOT": "macosx",
    "SYMROOT": '"$(PROJECT_DIR)/build"',
    "SWIFT_VERSION": "5.0",
}
debug_project = dict(common_project)
debug_project.update({
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
})
release_project = dict(common_project)
release_project.update({
    "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
    "GCC_OPTIMIZATION_LEVEL": "s",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
})

project_debug = build_config("Debug", debug_project)
project_release = build_config("Release", release_project)
project_config_list = oid()
add(f'''\t\t{project_config_list} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{project_debug} /* Debug */,
\t\t\t\t{project_release} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};''')
for cid in (project_debug, project_release):
    # Replace placeholder after target config list is known.
    pass

common_target = {
    "CODE_SIGN_IDENTITY": '"-"',
    "CODE_SIGN_STYLE": "Manual",
    "COMBINE_HIDPI_IMAGES": "YES",
    "CURRENT_PROJECT_VERSION": "1",
    "DEVELOPMENT_TEAM": '""',
    "ENABLE_APP_SANDBOX": "NO",
    "ENABLE_HARDENED_RUNTIME": "NO",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "Qdown/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/../Frameworks")',
    "MARKETING_VERSION": "1.0.0",
    "PRODUCT_BUNDLE_IDENTIFIER": "com.furuhama.qdown",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "PROVISIONING_PROFILE_SPECIFIER": '""',
    "SWIFT_EMIT_LOC_STRINGS": "NO",
    "SWIFT_VERSION": "5.0",
    "ARCHS": '"arm64 x86_64"',
    "ONLY_ACTIVE_ARCH": "NO",
    "SUPPORTED_PLATFORMS": "macosx",
    "MACOSX_DEPLOYMENT_TARGET": "13.0",
}
debug_target = dict(common_target)
debug_target.update({"SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG"})
release_target = dict(common_target)

target_debug = build_config("Debug", debug_target)
target_release = build_config("Release", release_target)
target_config_list = oid()
add(f'''\t\t{target_config_list} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{target_debug} /* Debug */,
\t\t\t\t{target_release} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};''')

text = "\n".join([
    "// !$*UTF8*$!",
    "{",
    "\tarchiveVersion = 1;",
    "\tclasses = {",
    "\t};",
    "\tobjectVersion = 56;",
    "\tobjects = {",
    *objects,
    "\t};",
    f"\trootObject = {project} /* Project object */;",
    "}",
    "",
])
text = text.replace("{TARGET_CONFIG_LIST}", target_config_list)
text = text.replace("{PROJECT_CONFIG_LIST}", project_config_list)
(PROJECT / "project.pbxproj").write_text(text, encoding="utf-8")
print("wrote", PROJECT / "project.pbxproj", len(text), "bytes")

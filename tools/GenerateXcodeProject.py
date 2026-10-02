#!/usr/bin/env python3
"""
GenerateXcodeProject.py — creates Cadence.xcodeproj (project.pbxproj) from the
files on disk, with no dependency on XcodeGen or Ruby.

Why this exists: the project was authored on a machine without Xcode, so the
.pbxproj is generated rather than hand-typed (hand-typed pbxproj files rot fast).
Run it after adding, renaming or deleting a Swift file:

    python3 tools/GenerateXcodeProject.py

It is idempotent: run it as often as you like.

Targets produced
    Cadence        — iOS app (SwiftUI + SwiftData)
    CadenceWidget  — WidgetKit extension (shares CadenceShared/*.swift)
    CadenceTests   — unit tests for the scheduling engine
"""

from __future__ import annotations

import hashlib
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT_NAME = "Cadence"
PROJECT_DIR = os.path.join(ROOT, f"{PROJECT_NAME}.xcodeproj")

APP_TARGET = "Cadence"
WIDGET_TARGET = "CadenceWidget"
TEST_TARGET = "CadenceTests"

APP_BUNDLE_ID = "com.example.cadence"
WIDGET_BUNDLE_ID = "com.example.cadence.widget"
TEST_BUNDLE_ID = "com.example.cadence.tests"
APP_GROUP = "group.com.example.cadence"
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "5.0"

# Pure Swift core: no SwiftUI / SwiftData / EventKit. Compiled into the app, the widget
# and — as a standalone SwiftPM package (see Package.swift) — into the Linux CI test run.
CORE_DIR = "CadenceCore"
CORE_TESTS_DIR = "CadenceCoreTests"

# Files shared between the app and the widget extension.
SHARED_DIR = "CadenceShared"

# App files the widget also needs (brand colours, shared design tokens).
WIDGET_EXTRAS = ["Cadence/DesignSystem/Theme.swift"]

# Every directory that becomes a navigator group root.
TARGET_ROOTS = [APP_TARGET, CORE_DIR, SHARED_DIR, WIDGET_TARGET, TEST_TARGET, CORE_TESTS_DIR]

SOURCE_EXCLUDES = {"Info.plist", ".DS_Store"}


def uid(*parts: str) -> str:
    """Stable 24-hex-char identifier, so regenerating doesn't churn the file."""
    digest = hashlib.md5("::".join(parts).encode("utf-8")).hexdigest().upper()
    return digest[:24]


def swift_files(rel_dir: str) -> list[str]:
    directory = os.path.join(ROOT, rel_dir)
    if not os.path.isdir(directory):
        return []
    found = []
    for current, _dirs, files in os.walk(directory):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            if name in SOURCE_EXCLUDES:
                continue
            found.append(os.path.relpath(os.path.join(current, name), ROOT))
    return sorted(found)


def tree_dirs(rel_dir: str) -> list[str]:
    """Directories that become navigator groups.

    Asset catalogs are file references, not groups, and their contents (.appiconset,
    .colorset …) are not navigator nodes — so anything inside an .xcassets is skipped.
    """
    directory = os.path.join(ROOT, rel_dir)
    result = []
    for current, dirs, _files in os.walk(directory):
        dirs.sort()
        if ".xcassets" in current:
            dirs[:] = []
            continue
        for name in dirs:
            if name.endswith(".xcassets"):
                continue
            result.append(os.path.relpath(os.path.join(current, name), ROOT))
    return sorted(result)


class ProjectWriter:
    def __init__(self) -> None:
        self.objects: list[str] = []

    def add(self, identifier: str, body: str) -> None:
        self.objects.append(f"\t\t{identifier} = {body};")

    def render(self) -> str:
        header = (
            "// !$*UTF8*$!\n"
            "{\n"
            "\tarchiveVersion = 1;\n"
            "\tclasses = {\n\t};\n"
            "\tobjectVersion = 56;\n"
            "\tobjects = {\n"
        )
        footer = (
            "\t};\n"
            "\trootObject = %s /* Project object */;\n}\n" % uid("project", PROJECT_NAME)
        )
        return header + "\n".join(sorted(self.objects)) + "\n" + footer


def build_target_files() -> tuple[list[str], list[str], list[str], list[str]]:
    core_files = swift_files(CORE_DIR)
    shared_files = swift_files(SHARED_DIR)
    extras = [p for p in WIDGET_EXTRAS if os.path.exists(os.path.join(ROOT, p))]

    # App: everything in Cadence/ + the shared glue + the core.
    app_files = sorted(set(swift_files("Cadence") + shared_files + core_files))
    # Widget: its own sources + shared glue + core + the few app files it reuses.
    widget_files = sorted(set(swift_files(WIDGET_TARGET) + shared_files + core_files + extras))
    # Tests: app-level tests plus the core tests (which run in Xcode via the app module,
    # and standalone via `swift test`).
    test_files = sorted(set(swift_files("CadenceTests") + swift_files(CORE_TESTS_DIR)))

    return app_files, shared_files, widget_files, test_files


def emit_file_reference(writer: ProjectWriter, path: str, file_type: str) -> str:
    """One PBXFileReference; `path` is relative to the owning group (its directory)."""
    identifier = uid("fileref", path)
    basename = os.path.basename(path)
    writer.add(
        identifier,
        f'{{isa = PBXFileReference; lastKnownFileType = {file_type}; path = "{basename}"; sourceTree = "<group>"; }}',
    )
    return identifier


def file_type(path: str) -> str:
    if path.endswith(".swift"):
        return "sourcecode.swift"
    if path.endswith(".plist"):
        return "text.plist.xml"
    if path.endswith(".entitlements"):
        return "text.plist.entitlements"
    if path.endswith(".xcassets"):
        return "folder.assetcatalog"
    if path.endswith(".xcprivacy"):
        return "text.plist.xml"
    return "text"


def emit_build_file(writer: ProjectWriter, file_ref: str, target: str, phase: str) -> str:
    identifier = uid("buildfile", target, file_ref)
    writer.add(
        identifier,
        f"{{isa = PBXBuildFile; fileRef = {file_ref} /* {phase} */; }}",
    )
    return identifier


def main() -> int:
    writer = ProjectWriter()

    app_sources, shared_sources, widget_sources, test_sources = build_target_files()

    if not app_sources:
        print("No Swift files found — aborting.", file=sys.stderr)
        return 1

    # ---------------------------------------------------------------- groups
    app_group = uid("group", APP_TARGET)
    shared_group = uid("group", SHARED_DIR)
    widget_group = uid("group", WIDGET_TARGET)
    tests_group = uid("group", TEST_TARGET)
    products_group = uid("group", "Products")
    root_group = uid("group", "root")

    # Every directory that will become a navigator group, mapped to that group's id.
    # The four target roots are groups in their own right (they carry the path), so
    # each file reference resolves to the right place on disk.
    core_group = uid("group", CORE_DIR)
    core_tests_group = uid("group", CORE_TESTS_DIR)

    dir_groups: dict[str, str] = {
        APP_TARGET: app_group,
        CORE_DIR: core_group,
        SHARED_DIR: shared_group,
        WIDGET_TARGET: widget_group,
        TEST_TARGET: tests_group,
        CORE_TESTS_DIR: core_tests_group,
    }
    for root_dir in TARGET_ROOTS:
        for directory in tree_dirs(root_dir):
            dir_groups[directory] = uid("group", directory)

    # ------------------------------------------------------- file references
    file_refs: dict[str, str] = {}
    for path in sorted(set(app_sources + widget_sources + test_sources)):
        file_refs[path] = emit_file_reference(writer, path, file_type(path))

    extra_refs: dict[str, str] = {}
    for path in [
        "Cadence/Resources/Info.plist",
        "Cadence/Cadence.entitlements",
        "CadenceWidget/Resources/Info.plist",
        "CadenceWidget/CadenceWidget.entitlements",
    ]:
        if os.path.exists(os.path.join(ROOT, path)):
            extra_refs[path] = emit_file_reference(writer, path, file_type(path))

    assets_ref = None
    assets_path = "Cadence/Resources/Assets.xcassets"
    if os.path.isdir(os.path.join(ROOT, assets_path)):
        assets_ref = uid("fileref", assets_path)
        writer.add(
            assets_ref,
            '{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; '
            'sourceTree = "<group>"; }',
        )

    package_ref = None
    if os.path.exists(os.path.join(ROOT, "Package.swift")):
        package_ref = uid("fileref", "Package.swift")
        writer.add(
            package_ref,
            '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "Package.swift"; '
            'sourceTree = "<group>"; }',
        )

    readme_ref = None
    for candidate in ["SPEC.md", "README.md"]:
        full = os.path.join(ROOT, candidate)
        if os.path.exists(full):
            readme_ref = uid("fileref", candidate)
            writer.add(
                readme_ref,
                f'{{isa = PBXFileReference; lastKnownFileType = net.daringfireball.markdown; path = "{candidate}"; '
                f'sourceTree = "<group>"; }}',
            )
            break

    # Products
    app_product = uid("product", APP_TARGET)
    widget_product = uid("product", WIDGET_TARGET)
    test_product = uid("product", TEST_TARGET)
    writer.add(app_product, f'{{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "{APP_TARGET}.app"; sourceTree = BUILT_PRODUCTS_DIR; }}')
    writer.add(widget_product, f'{{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = "{WIDGET_TARGET}.appex"; sourceTree = BUILT_PRODUCTS_DIR; }}')
    writer.add(test_product, f'{{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = "{TEST_TARGET}.xctest"; sourceTree = BUILT_PRODUCTS_DIR; }}')

    # -------------------------------------------------- group membership maps
    children: dict[str, list[str]] = {}

    def attach(parent: str, child: str) -> None:
        children.setdefault(parent, []).append(child)

    def group_for_path(path: str) -> str:
        """The group a file at `path` belongs to (its own directory)."""
        directory = os.path.dirname(path)
        group = dir_groups.get(directory)
        if group is None:
            raise SystemExit(f"No group registered for directory '{directory}' (file {path})")
        return group

    for path, ref in sorted(file_refs.items()):
        attach(group_for_path(path), ref)
    for path, ref in sorted(extra_refs.items()):
        attach(group_for_path(path), ref)
    if assets_ref:
        attach(group_for_path("Cadence/Resources/Assets.xcassets"), assets_ref)
    if readme_ref:
        attach(root_group, readme_ref)
    if package_ref:
        attach(root_group, package_ref)

    # Link nested directories to their parents.
    for directory, identifier in dir_groups.items():
        if directory in TARGET_ROOTS:
            continue
        parent_dir = os.path.dirname(directory)
        if parent_dir in dir_groups:
            attach(dir_groups[parent_dir], identifier)

    attach(root_group, app_group)
    attach(root_group, core_group)
    attach(root_group, core_tests_group)
    attach(root_group, shared_group)
    attach(root_group, widget_group)
    attach(root_group, tests_group)
    attach(root_group, products_group)
    attach(products_group, app_product)
    attach(products_group, widget_product)
    attach(products_group, test_product)

    # Render the groups that have no explicit special-casing below.
    special = {root_group, app_group, core_group, core_tests_group, shared_group, widget_group, tests_group, products_group}
    for directory, identifier in sorted(dir_groups.items()):
        if identifier in special:
            continue
        body = ", ".join(children.get(identifier, []))
        writer.add(
            identifier,
            f'{{isa = PBXGroup; children = ({body}); name = "{os.path.basename(directory)}"; '
            f'path = "{os.path.basename(directory)}"; sourceTree = "<group>"; }}',
        )

    # -------------------------------------------------------- build phases
    app_source_builds = [emit_build_file(writer, file_refs[p], APP_TARGET, "sources") for p in app_sources]
    widget_source_builds = [emit_build_file(writer, file_refs[p], WIDGET_TARGET, "sources") for p in widget_sources]
    test_source_builds = [emit_build_file(writer, file_refs[p], TEST_TARGET, "sources") for p in test_sources]

    app_resources = []
    if assets_ref:
        app_resources.append(emit_build_file(writer, assets_ref, APP_TARGET, "resources"))

    app_sources_phase = uid("phase", APP_TARGET, "sources")
    app_frameworks_phase = uid("phase", APP_TARGET, "frameworks")
    app_resources_phase = uid("phase", APP_TARGET, "resources")
    app_embed_phase = uid("phase", APP_TARGET, "embed")

    writer.add(app_sources_phase, f'{{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(app_source_builds)}); runOnlyForDeploymentPostprocessing = 0; }}')
    writer.add(app_frameworks_phase, '{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }')
    writer.add(app_resources_phase, f'{{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(app_resources)}); runOnlyForDeploymentPostprocessing = 0; }}')

    widget_build_file = uid("buildfile", APP_TARGET, widget_product)
    writer.add(
        widget_build_file,
        f'{{isa = PBXBuildFile; fileRef = {widget_product} /* {WIDGET_TARGET}.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }}',
    )
    writer.add(
        app_embed_phase,
        f'{{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; '
        f'files = ({widget_build_file}); name = "Embed Foundation Extensions"; runOnlyForDeploymentPostprocessing = 0; }}',
    )

    widget_sources_phase = uid("phase", WIDGET_TARGET, "sources")
    widget_frameworks_phase = uid("phase", WIDGET_TARGET, "frameworks")
    widget_resources_phase = uid("phase", WIDGET_TARGET, "resources")
    writer.add(widget_sources_phase, f'{{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(widget_source_builds)}); runOnlyForDeploymentPostprocessing = 0; }}')
    writer.add(widget_frameworks_phase, '{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }')
    writer.add(widget_resources_phase, '{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }')

    test_sources_phase = uid("phase", TEST_TARGET, "sources")
    test_frameworks_phase = uid("phase", TEST_TARGET, "frameworks")
    test_resources_phase = uid("phase", TEST_TARGET, "resources")
    writer.add(test_sources_phase, f'{{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(test_source_builds)}); runOnlyForDeploymentPostprocessing = 0; }}')
    writer.add(test_frameworks_phase, '{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }')
    writer.add(test_resources_phase, '{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }')

    # ------------------------------------------------------------- targets
    app_target = uid("target", APP_TARGET)
    widget_target = uid("target", WIDGET_TARGET)
    test_target = uid("target", TEST_TARGET)

    widget_dependency = uid("dependency", APP_TARGET, WIDGET_TARGET)
    widget_proxy = uid("proxy", APP_TARGET, WIDGET_TARGET)
    writer.add(
        widget_proxy,
        f'{{isa = PBXContainerItemProxy; containerPortal = {uid("project", PROJECT_NAME)} /* Project object */; '
        f'proxyType = 1; remoteGlobalIDString = {widget_target}; remoteInfo = {WIDGET_TARGET}; }}',
    )
    writer.add(widget_dependency, f'{{isa = PBXTargetDependency; target = {widget_target}; targetProxy = {widget_proxy}; }}')

    test_dependency = uid("dependency", APP_TARGET, TEST_TARGET)
    test_proxy = uid("proxy", APP_TARGET, TEST_TARGET)
    writer.add(
        test_proxy,
        f'{{isa = PBXContainerItemProxy; containerPortal = {uid("project", PROJECT_NAME)} /* Project object */; '
        f'proxyType = 1; remoteGlobalIDString = {app_target}; remoteInfo = {APP_TARGET}; }}',
    )
    writer.add(test_dependency, f'{{isa = PBXTargetDependency; target = {app_target}; targetProxy = {test_proxy}; }}')

    writer.add(
        app_target,
        f'{{isa = PBXNativeTarget; buildConfigurationList = {uid("cfglist", APP_TARGET)}; '
        f'buildPhases = ({app_sources_phase}, {app_frameworks_phase}, {app_resources_phase}, {app_embed_phase}); '
        f'buildRules = (); dependencies = ({widget_dependency}); name = {APP_TARGET}; '
        f'productName = {APP_TARGET}; productReference = {app_product}; productType = "com.apple.product-type.application"; }}',
    )
    writer.add(
        widget_target,
        f'{{isa = PBXNativeTarget; buildConfigurationList = {uid("cfglist", WIDGET_TARGET)}; '
        f'buildPhases = ({widget_sources_phase}, {widget_frameworks_phase}, {widget_resources_phase}); '
        f'buildRules = (); dependencies = (); name = {WIDGET_TARGET}; '
        f'productName = {WIDGET_TARGET}; productReference = {widget_product}; '
        f'productType = "com.apple.product-type.app-extension"; }}',
    )
    writer.add(
        test_target,
        f'{{isa = PBXNativeTarget; buildConfigurationList = {uid("cfglist", TEST_TARGET)}; '
        f'buildPhases = ({test_sources_phase}, {test_frameworks_phase}, {test_resources_phase}); '
        f'buildRules = (); dependencies = ({test_dependency}); name = {TEST_TARGET}; '
        f'productName = {TEST_TARGET}; productReference = {test_product}; '
        f'productType = "com.apple.product-type.bundle.unit-test"; }}',
    )

    # ------------------------------------------------------------ project
    writer.add(
        uid("project", PROJECT_NAME),
        f'{{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 1500; '
        f'LastUpgradeCheck = 1500; TargetAttributes = {{ {app_target} = {{CreatedOnToolsVersion = 15.0; }}; '
        f'{widget_target} = {{CreatedOnToolsVersion = 15.0; }}; {test_target} = {{CreatedOnToolsVersion = 15.0; TestTargetID = {app_target}; }}; }}; }}; '
        f'buildConfigurationList = {uid("cfglist", "project")}; compatibilityVersion = "Xcode 14.0"; '
        f'developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); '
        f'mainGroup = {uid("group", "root")}; productRefGroup = {products_group}; '
        f'projectDirPath = ""; projectRoot = ""; targets = ({app_target}, {widget_target}, {test_target}); }}',
    )

    writer.add(
        root_group,
        f'{{isa = PBXGroup; children = ({", ".join(children.get(root_group, []))}); sourceTree = "<group>"; }}',
    )
    writer.add(
        app_group,
        f'{{isa = PBXGroup; children = ({", ".join(children.get(app_group, []))}); path = {APP_TARGET}; sourceTree = "<group>"; }}',
    )
    writer.add(
        core_group,
        f'{{isa = PBXGroup; children = ({", ".join(children.get(core_group, []))}); path = {CORE_DIR}; sourceTree = "<group>"; }}',
    )
    writer.add(
        core_tests_group,
        f'{{isa = PBXGroup; children = ({", ".join(children.get(core_tests_group, []))}); path = {CORE_TESTS_DIR}; sourceTree = "<group>"; }}',
    )
    writer.add(
        shared_group,
        f'{{isa = PBXGroup; children = ({", ".join(children.get(shared_group, []))}); name = {SHARED_DIR}; path = {SHARED_DIR}; sourceTree = "<group>"; }}',
    )
    writer.add(
        widget_group,
        f'{{isa = PBXGroup; children = ({", ".join(children.get(widget_group, []))}); path = {WIDGET_TARGET}; sourceTree = "<group>"; }}',
    )
    writer.add(
        tests_group,
        f'{{isa = PBXGroup; children = ({", ".join(children.get(tests_group, []))}); path = {TEST_TARGET}; sourceTree = "<group>"; }}',
    )
    writer.add(
        products_group,
        f'{{isa = PBXGroup; children = ({", ".join(children.get(products_group, []))}); name = Products; sourceTree = "<group>"; }}',
    )

    # --------------------------------------------------- build configurations
    def project_settings(config: str) -> str:
        common = [
            ("ALWAYS_SEARCH_USER_PATHS", "NO"),
            ("CLANG_ANALYZER_NONNULL", "YES"),
            ("CLANG_ENABLE_MODULES", "YES"),
            ("CLANG_ENABLE_OBJC_ARC", "YES"),
            ("CLANG_WARN_BOOL_CONVERSION", "YES"),
            ("CLANG_WARN_DOCUMENTATION_COMMENTS", "YES"),
            ("CLANG_WARN_EMPTY_BODY", "YES"),
            ("CLANG_WARN_UNREACHABLE_CODE", "YES"),
            ("COPY_PHASE_STRIP", "NO"),
            ("ENABLE_STRICT_OBJC_MSGSEND", "YES"),
            ("GCC_C_LANGUAGE_STANDARD", "gnu17"),
            ("GCC_NO_COMMON_BLOCKS", "YES"),
            ("GCC_WARN_UNDECLARED_SELECTOR", "YES"),
            ("IPHONEOS_DEPLOYMENT_TARGET", DEPLOYMENT_TARGET),
            ("LOCALIZATION_PREFERS_STRING_CATALOGS", "YES"),
            ("MTL_FAST_MATH", "YES"),
            ("SDKROOT", "iphoneos"),
            ("SWIFT_VERSION", SWIFT_VERSION),
            ("ENABLE_USER_SCRIPT_SANDBOXING", "YES"),
        ]
        debug = [
            ("DEBUG_INFORMATION_FORMAT", "dwarf"),
            ("ENABLE_TESTABILITY", "YES"),
            ("GCC_DYNAMIC_NO_PIC", "NO"),
            ("GCC_OPTIMIZATION_LEVEL", "0"),
            ("GCC_PREPROCESSOR_DEFINITIONS", '("DEBUG=1", "$(inherited)")'),
            ("MTL_ENABLE_DEBUG_INFO", "INCLUDE_SOURCE"),
            ("ONLY_ACTIVE_ARCH", "YES"),
            ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"),
            ("SWIFT_OPTIMIZATION_LEVEL", '"-Onone"'),
        ]
        release = [
            ("DEBUG_INFORMATION_FORMAT", '"dwarf-with-dsym"'),
            ("ENABLE_NS_ASSERTIONS", "NO"),
            ("MTL_ENABLE_DEBUG_INFO", "NO"),
            ("SWIFT_COMPILATION_MODE", "wholemodule"),
            ("VALIDATE_PRODUCT", "YES"),
        ]
        settings = common + (debug if config == "Debug" else release)
        body = " ".join(f"{k} = {v};" for k, v in settings)
        return f"{{isa = XCBuildConfiguration; buildSettings = {{{body}}}; name = {config}; }}"

    for config in ("Debug", "Release"):
        identifier = uid("cfg", "project", config)
        writer.add(identifier, project_settings(config))
    writer.add(
        uid("cfglist", "project"),
        f'{{isa = XCConfigurationList; buildConfigurations = ({uid("cfg", "project", "Debug")}, {uid("cfg", "project", "Release")}); '
        f'defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}',
    )

    app_common = [
        ("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon"),
        ("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", "AccentColor"),
        ("CODE_SIGN_ENTITLEMENTS", "Cadence/Cadence.entitlements"),
        ("CODE_SIGN_STYLE", "Automatic"),
        ("CURRENT_PROJECT_VERSION", "1"),
        ("DEVELOPMENT_ASSET_PATHS", '"Cadence/Resources/Preview Content"'),
        ("ENABLE_PREVIEWS", "YES"),
        ("GENERATE_INFOPLIST_FILE", "NO"),
        ("INFOPLIST_FILE", "Cadence/Resources/Info.plist"),
        ("INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents", "YES"),
        ("LD_RUNPATH_SEARCH_PATHS", '("$(inherited)", "@executable_path/Frameworks")'),
        ("MARKETING_VERSION", "1.0.0"),
        ("PRODUCT_BUNDLE_IDENTIFIER", APP_BUNDLE_ID),
        ("PRODUCT_NAME", '"$(TARGET_NAME)"'),
        ("SWIFT_EMIT_LOC_STRINGS", "YES"),
        ("TARGETED_DEVICE_FAMILY", '"1,2"'),
    ]

    widget_common = [
        ("APPLICATION_EXTENSION_API_ONLY", "YES"),
        ("CODE_SIGN_ENTITLEMENTS", "CadenceWidget/CadenceWidget.entitlements"),
        ("CODE_SIGN_STYLE", "Automatic"),
        ("CURRENT_PROJECT_VERSION", "1"),
        ("GENERATE_INFOPLIST_FILE", "NO"),
        ("INFOPLIST_FILE", "CadenceWidget/Resources/Info.plist"),
        ("LD_RUNPATH_SEARCH_PATHS", '("$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks")'),
        ("MARKETING_VERSION", "1.0.0"),
        ("PRODUCT_BUNDLE_IDENTIFIER", WIDGET_BUNDLE_ID),
        ("PRODUCT_NAME", '"$(TARGET_NAME)"'),
        ("SKIP_INSTALL", "YES"),
        ("SWIFT_EMIT_LOC_STRINGS", "YES"),
        ("TARGETED_DEVICE_FAMILY", '"1,2"'),
    ]

    test_common = [
        ("BUNDLE_LOADER", '"$(TEST_HOST)"'),
        ("CURRENT_PROJECT_VERSION", "1"),
        ("GENERATE_INFOPLIST_FILE", "YES"),
        ("MARKETING_VERSION", "1.0.0"),
        ("PRODUCT_BUNDLE_IDENTIFIER", TEST_BUNDLE_ID),
        ("PRODUCT_NAME", '"$(TARGET_NAME)"'),
        ("SWIFT_EMIT_LOC_STRINGS", "YES"),
        ("TARGETED_DEVICE_FAMILY", '"1,2"'),
        ("TEST_HOST", '"$(BUILT_PRODUCTS_DIR)/Cadence.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Cadence"'),
    ]

    for target, settings in (
        (APP_TARGET, app_common),
        (WIDGET_TARGET, widget_common),
        (TEST_TARGET, test_common),
    ):
        for config in ("Debug", "Release"):
            identifier = uid("cfg", target, config)
            body = " ".join(f"{k} = {v};" for k, v in settings)
            writer.add(identifier, f"{{isa = XCBuildConfiguration; buildSettings = {{{body}}}; name = {config}; }}")
        writer.add(
            uid("cfglist", target),
            f'{{isa = XCConfigurationList; buildConfigurations = ({uid("cfg", target, "Debug")}, {uid("cfg", target, "Release")}); '
            f'defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}',
        )

    # ----------------------------------------------------------------- write
    os.makedirs(PROJECT_DIR, exist_ok=True)
    with open(os.path.join(PROJECT_DIR, "project.pbxproj"), "w", encoding="utf-8") as handle:
        handle.write(writer.render())

    workspace_dir = os.path.join(PROJECT_DIR, "project.xcworkspace")
    os.makedirs(workspace_dir, exist_ok=True)
    with open(os.path.join(workspace_dir, "contents.xcworkspacedata"), "w", encoding="utf-8") as handle:
        handle.write(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<Workspace version = "1.0">\n'
            '   <FileRef location = "self:">\n   </FileRef>\n'
            "</Workspace>\n"
        )

    schemes_dir = os.path.join(PROJECT_DIR, "xcshareddata", "xcschemes")
    os.makedirs(schemes_dir, exist_ok=True)
    with open(os.path.join(schemes_dir, f"{APP_TARGET}.xcscheme"), "w", encoding="utf-8") as handle:
        handle.write(render_scheme())

    print(f"Wrote {os.path.relpath(PROJECT_DIR, ROOT)}")
    print(f"  core sources    : {len(swift_files(CORE_DIR))}  (also built as the CadenceCore SwiftPM package)")
    print(f"  app sources     : {len(app_sources)}")
    print(f"  shared sources  : {len(shared_sources)}")
    print(f"  widget sources  : {len(widget_sources)}")
    print(f"  test sources    : {len(test_sources)}")
    return 0


def render_scheme() -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1500" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{uid('target', APP_TARGET)}"
               BuildableName = "{APP_TARGET}.app"
               BlueprintName = "{APP_TARGET}"
               ReferencedContainer = "container:{APP_TARGET}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{uid('target', TEST_TARGET)}"
               BuildableName = "{TEST_TARGET}.xctest"
               BlueprintName = "{TEST_TARGET}"
               ReferencedContainer = "container:{APP_TARGET}.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{uid('target', APP_TARGET)}"
            BuildableName = "{APP_TARGET}.app"
            BlueprintName = "{APP_TARGET}"
            ReferencedContainer = "container:{APP_TARGET}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{uid('target', APP_TARGET)}"
            BuildableName = "{APP_TARGET}.app"
            BlueprintName = "{APP_TARGET}"
            ReferencedContainer = "container:{APP_TARGET}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"/>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"/>
</Scheme>
"""


if __name__ == "__main__":
    sys.exit(main())

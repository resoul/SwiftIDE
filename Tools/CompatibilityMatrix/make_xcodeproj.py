#!/usr/bin/env python3
"""Writes the small .xcodeproj files of the TK-009 fixtures.

There is no project generator on the machine (and none is wanted as a dependency), and a fixture
must be a project that Xcode itself would write, so this emits the plain pbxproj text for the few
shapes the matrix needs: an app or a framework target, several configurations that differ in a
compilation condition, source files in groups, a dependency on another target of the same
project, on a framework built by another project of the workspace, on a local package, and a Run
Script phase.

Usage: make_xcodeproj.py            (rewrites every fixture under Fixtures/)
"""
import hashlib
import os
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "Fixtures"


def ident(*parts):
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


def q(value):
    value = str(value)
    if value and all(c.isalnum() or c in "._/" for c in value):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


class Project:
    def __init__(self, name, directory):
        self.name = name
        self.directory = Path(directory)
        self.targets = []
        self.local_packages = []   # (relative path)

    def target(self, **spec):
        self.targets.append(spec)
        return spec

    # -- rendering ---------------------------------------------------------------------------

    def render(self):
        out = []
        objects = {"PBXBuildFile": [], "PBXFileReference": [], "PBXGroup": [], "PBXNativeTarget": [],
                   "PBXProject": [], "PBXSourcesBuildPhase": [], "PBXFrameworksBuildPhase": [],
                   "PBXShellScriptBuildPhase": [], "PBXTargetDependency": [], "PBXContainerItemProxy": [],
                   "XCBuildConfiguration": [], "XCConfigurationList": [],
                   "XCLocalSwiftPackageReference": [], "XCSwiftPackageProductDependency": []}
        project_id = ident(self.name, "project")
        main_group = ident(self.name, "group", "main")
        products_group = ident(self.name, "group", "products")
        package_refs = []
        for path in self.local_packages:
            pid = ident(self.name, "package", path)
            package_refs.append(pid)
            objects["XCLocalSwiftPackageReference"].append(
                f"\t\t{pid} /* XCLocalSwiftPackageReference \"{path}\" */ = {{isa = XCLocalSwiftPackageReference; relativePath = {q(path)}; }};")

        # Source files: one group per directory.
        sources = []
        for spec in self.targets:
            for s in spec["sources"]:
                if s not in sources:
                    sources.append(s)
        file_ids = {s: ident(self.name, "file", s) for s in sources}
        for s in sources:
            objects["PBXFileReference"].append(
                f"\t\t{file_ids[s]} /* {os.path.basename(s)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(os.path.basename(s))}; sourceTree = \"<group>\"; }};")

        groups = {}
        for s in sources:
            groups.setdefault(os.path.dirname(s), []).append(s)
        group_ids = []
        for directory, files in groups.items():
            gid = ident(self.name, "group", directory)
            group_ids.append(gid)
            children = ", ".join(file_ids[f] for f in files)
            path_part = f" path = {q(directory)};" if directory else ""
            objects["PBXGroup"].append(
                f"\t\t{gid} /* {directory or 'Sources'} */ = {{isa = PBXGroup; children = ({children}); {path_part} sourceTree = \"<group>\"; }};")

        target_ids = []
        product_ids = []
        for spec in self.targets:
            tname = spec["name"]
            tid = ident(self.name, "target", tname)
            target_ids.append(tid)
            kind = spec.get("kind", "app")
            ext = {"app": "app", "framework": "framework"}[kind]
            ptype = {"app": "com.apple.product-type.application", "framework": "com.apple.product-type.framework"}[kind]
            pref = ident(self.name, "product", tname)
            product_ids.append(pref)
            ftype = {"app": "wrapper.application", "framework": "wrapper.framework"}[kind]
            objects["PBXFileReference"].append(
                f"\t\t{pref} /* {tname}.{ext} */ = {{isa = PBXFileReference; explicitFileType = {ftype}; includeInIndex = 0; path = {q(tname + '.' + ext)}; sourceTree = BUILT_PRODUCTS_DIR; }};")

            phases = []
            if spec.get("script"):
                sid = ident(self.name, "script", tname)
                phases.append(f"{sid} /* Generate */")
                objects["PBXShellScriptBuildPhase"].append(
                    f"\t\t{sid} /* Generate */ = {{\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\tinputPaths = (\n\t\t\t);\n\t\t\tname = Generate;\n\t\t\toutputPaths = (\n\t\t\t\t{q(spec['script']['output'])},\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t\tshellPath = /bin/sh;\n\t\t\tshellScript = {q(spec['script']['text'])};\n\t\t}};")
            src_id = ident(self.name, "sources", tname)
            phases.append(f"{src_id} /* Sources */")
            build_files = []
            for s in spec["sources"]:
                bid = ident(self.name, "build", tname, s)
                build_files.append(f"{bid} /* {os.path.basename(s)} in Sources */")
                objects["PBXBuildFile"].append(
                    f"\t\t{bid} /* {os.path.basename(s)} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ids[s]} /* {os.path.basename(s)} */; }};")
            files_text = "".join(f"\n\t\t\t\t{b}," for b in build_files)
            objects["PBXSourcesBuildPhase"].append(
                f"\t\t{src_id} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = ({files_text}\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")

            # Frameworks phase: other targets of this project, frameworks of sibling projects, packages.
            fw_id = ident(self.name, "frameworks", tname)
            phases.append(f"{fw_id} /* Frameworks */")
            fw_files = []
            dependencies = []
            product_dependencies = []
            for dep in spec.get("depends_on", []):
                dep_id = ident(self.name, "target", dep)
                proxy = ident(self.name, "proxy", tname, dep)
                tdep = ident(self.name, "dependency", tname, dep)
                objects["PBXContainerItemProxy"].append(
                    f"\t\t{proxy} /* PBXContainerItemProxy */ = {{isa = PBXContainerItemProxy; containerPortal = {project_id} /* Project object */; proxyType = 1; remoteGlobalIDString = {dep_id}; remoteInfo = {q(dep)}; }};")
                objects["PBXTargetDependency"].append(
                    f"\t\t{tdep} /* PBXTargetDependency */ = {{isa = PBXTargetDependency; target = {dep_id} /* {dep} */; targetProxy = {proxy} /* PBXContainerItemProxy */; }};")
                dependencies.append(f"{tdep} /* PBXTargetDependency */")
                fref = ident(self.name, "product", dep)
                bid = ident(self.name, "link", tname, dep)
                fw_files.append(f"{bid} /* {dep}.framework in Frameworks */")
                objects["PBXBuildFile"].append(
                    f"\t\t{bid} /* {dep}.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {fref} /* {dep}.framework */; }};")
            for fw in spec.get("links_built_framework", []):
                fref = ident(self.name, "external", fw)
                objects["PBXFileReference"].append(
                    f"\t\t{fref} /* {fw}.framework */ = {{isa = PBXFileReference; explicitFileType = wrapper.framework; path = {q(fw + '.framework')}; sourceTree = BUILT_PRODUCTS_DIR; }};")
                bid = ident(self.name, "link", tname, fw)
                fw_files.append(f"{bid} /* {fw}.framework in Frameworks */")
                objects["PBXBuildFile"].append(
                    f"\t\t{bid} /* {fw}.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {fref} /* {fw}.framework */; }};")
                product_ids.append(None)
                extra_group_child = fref
                spec.setdefault("_external_refs", []).append(fref)
            for pkg, product in spec.get("package_products", []):
                dep_id = ident(self.name, "pkgdep", tname, product)
                bid = ident(self.name, "pkgbuild", tname, product)
                objects["XCSwiftPackageProductDependency"].append(
                    f"\t\t{dep_id} /* {product} */ = {{isa = XCSwiftPackageProductDependency; productName = {q(product)}; }};")
                objects["PBXBuildFile"].append(
                    f"\t\t{bid} /* {product} in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep_id} /* {product} */; }};")
                fw_files.append(f"{bid} /* {product} in Frameworks */")
                product_dependencies.append(f"{dep_id} /* {product} */")
            fw_text = "".join(f"\n\t\t\t\t{b}," for b in fw_files)
            objects["PBXFrameworksBuildPhase"].append(
                f"\t\t{fw_id} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = ({fw_text}\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")

            # Configurations.
            cfg_ids = []
            for config in ("Debug", "Release"):
                cid = ident(self.name, "config", tname, config)
                cfg_ids.append(cid)
                settings = dict(spec["settings"])
                settings.update(spec.get("settings_" + config.lower(), {}))
                body = "".join(f"\n\t\t\t\t{k} = {q(v)};" for k, v in sorted(settings.items()))
                objects["XCBuildConfiguration"].append(
                    f"\t\t{cid} /* {config} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{{body}\n\t\t\t}};\n\t\t\tname = {config};\n\t\t}};")
            lid = ident(self.name, "configlist", tname)
            objects["XCConfigurationList"].append(
                f"\t\t{lid} /* Build configuration list for PBXNativeTarget \"{tname}\" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{cfg_ids[0]} /* Debug */,\n\t\t\t\t{cfg_ids[1]} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = {self.default_configuration};\n\t\t}};")
            phases_text = "".join(f"\n\t\t\t\t{p}," for p in phases)
            deps_text = "".join(f"\n\t\t\t\t{d}," for d in dependencies)
            pd_text = "".join(f"\n\t\t\t\t{d}," for d in product_dependencies)
            objects["PBXNativeTarget"].append(
                f"\t\t{tid} /* {tname} */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {lid};\n\t\t\tbuildPhases = ({phases_text}\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = ({deps_text}\n\t\t\t);\n\t\t\tname = {q(tname)};\n\t\t\tpackageProductDependencies = ({pd_text}\n\t\t\t);\n\t\t\tproductName = {q(tname)};\n\t\t\tproductReference = {pref} /* {tname}.{ext} */;\n\t\t\tproductType = \"{ptype}\";\n\t\t}};")

        # Project-level.
        prefs = [p for p in product_ids if p]
        externals = [r for spec in self.targets for r in spec.get("_external_refs", [])]
        objects["PBXGroup"].append(
            f"\t\t{products_group} /* Products */ = {{isa = PBXGroup; children = ({', '.join(prefs + externals)}); name = Products; sourceTree = \"<group>\"; }};")
        objects["PBXGroup"].append(
            f"\t\t{main_group} = {{isa = PBXGroup; children = ({', '.join(group_ids + [products_group])}); sourceTree = \"<group>\"; }};")
        pcfg = []
        project_settings = self.project_settings
        for config in ("Debug", "Release"):
            cid = ident(self.name, "projectconfig", config)
            pcfg.append(cid)
            body = "".join(f"\n\t\t\t\t{k} = {q(v)};" for k, v in sorted(project_settings.items()))
            objects["XCBuildConfiguration"].append(
                f"\t\t{cid} /* {config} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{{body}\n\t\t\t}};\n\t\t\tname = {config};\n\t\t}};")
        plid = ident(self.name, "projectconfiglist")
        objects["XCConfigurationList"].append(
            f"\t\t{plid} /* Build configuration list for PBXProject \"{self.name}\" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{pcfg[0]} /* Debug */,\n\t\t\t\t{pcfg[1]} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = {self.default_configuration};\n\t\t}};")
        targets_text = "".join(f"\n\t\t\t\t{t}," for t in target_ids)
        packages_text = "".join(f"\n\t\t\t\t{p}," for p in package_refs)
        objects["PBXProject"].append(
            f"\t\t{project_id} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 2700;\n\t\t\t\tLastUpgradeCheck = 2700;\n\t\t\t}};\n\t\t\tbuildConfigurationList = {plid};\n\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n\t\t\tmainGroup = {main_group};\n\t\t\tpackageReferences = ({packages_text}\n\t\t\t);\n\t\t\tproductRefGroup = {products_group} /* Products */;\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = ({targets_text}\n\t\t\t);\n\t\t}};")

        text = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 60;", "\tobjects = {", ""]
        for section, items in objects.items():
            if not items:
                continue
            text.append(f"/* Begin {section} section */")
            text.extend(items)
            text.append(f"/* End {section} section */")
            text.append("")
        text += ["\t};", f"\trootObject = {project_id} /* Project object */;", "}", ""]
        return "\n".join(text)

    project_settings = {}
    default_configuration = "Release"

    def write(self):
        bundle = self.directory / f"{self.name}.xcodeproj"
        bundle.mkdir(parents=True, exist_ok=True)
        (bundle / "project.pbxproj").write_text(self.render())


def write_file(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(text).lstrip("\n"))


COMMON = {
    "SWIFT_VERSION": "6.0",
    "GENERATE_INFOPLIST_FILE": "YES",
    "CODE_SIGN_STYLE": "Manual",
    "CODE_SIGNING_ALLOWED": "NO",
    "CODE_SIGN_IDENTITY": "-",
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    "ALWAYS_SEARCH_USER_PATHS": "NO",
}


def mac_app():
    base = ROOT / "MacApp"
    write_file(base / "Sources/main.swift", """
        import AppKit

        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    """)
    write_file(base / "Sources/AppDelegate.swift", """
        import AppKit

        @MainActor
        final class AppDelegate: NSObject, NSApplicationDelegate {
            let greeter = Greeter(name: "mac")

            func applicationDidFinishLaunching(_ notification: Notification) {
                print(greeter.greeting(), Build.flavour)
            }
        }
    """)
    write_file(base / "Sources/Greeter.swift", """
        struct Greeter: Sendable {
            let name: String

            func greeting() -> String {
                "Hello, \\(name)!"
            }
        }
    """)
    write_file(base / "Sources/Build.swift", """
        // What differs between configurations: the compilation condition, set per configuration.
        enum Build {
        #if FLAVOUR_DEBUG
            static let flavour = "debug"
        #elseif FLAVOUR_RELEASE
            static let flavour = "release"
        #else
            static let flavour = "unknown"
        #endif
        }
    """)
    p = Project("MacApp", base)
    p.default_configuration = os.environ.get("MACAPP_DEFAULT_CONFIG", "Release")
    p.project_settings = {"SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0", "SWIFT_VERSION": "6.0"}
    extra = [s for s in os.environ.get("MACAPP_EXTRA", "").split(",") if s]
    p.target(
        name="MacApp", kind="app",
        sources=["Sources/main.swift", "Sources/AppDelegate.swift", "Sources/Greeter.swift", "Sources/Build.swift"] + extra,
        settings={**COMMON, "PRODUCT_BUNDLE_IDENTIFIER": "dev.swiftide.fixture.macapp", "PRODUCT_NAME": "$(TARGET_NAME)",
                  "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0"},
        settings_debug={"SWIFT_ACTIVE_COMPILATION_CONDITIONS": "FLAVOUR_DEBUG"},
        settings_release={"SWIFT_ACTIVE_COMPILATION_CONDITIONS": "FLAVOUR_RELEASE"},
    )
    p.write()


def ios_app():
    base = ROOT / "IOSApp"
    write_file(base / "Sources/AppDelegate.swift", """
        import UIKit

        @main
        final class AppDelegate: UIResponder, UIApplicationDelegate {
            var window: UIWindow?

            func application(
                _ application: UIApplication,
                didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
            ) -> Bool {
                let window = UIWindow(frame: UIScreen.main.bounds)
                window.rootViewController = RootViewController()
                window.makeKeyAndVisible()
                self.window = window
                return true
            }
        }
    """)
    write_file(base / "Sources/RootViewController.swift", """
        import UIKit

        final class RootViewController: UIViewController {
            let label = UILabel()

            override func viewDidLoad() {
                super.viewDidLoad()
                label.text = Greeter(name: "ios").greeting()
                view.addSubview(label)
            }
        }
    """)
    write_file(base / "Sources/Greeter.swift", """
        struct Greeter: Sendable {
            let name: String

            func greeting() -> String {
                "Hello, \\(name)!"
            }
        }
    """)
    p = Project("IOSApp", base)
    p.project_settings = {"SWIFT_VERSION": "6.0"}
    p.target(
        name="IOSApp", kind="app",
        sources=["Sources/AppDelegate.swift", "Sources/RootViewController.swift", "Sources/Greeter.swift"],
        settings={**COMMON, "PRODUCT_BUNDLE_IDENTIFIER": "dev.swiftide.fixture.iosapp", "PRODUCT_NAME": "$(TARGET_NAME)",
                  "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "TARGETED_DEVICE_FAMILY": "1,2",
                  "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "INFOPLIST_KEY_UILaunchScreen_Generation": "YES"},
    )
    p.write()


def workspace():
    base = ROOT / "Workspace"
    # A local package used by both projects.
    pkg = base / "LocalKit"
    write_file(pkg / "Package.swift", """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "LocalKit",
            platforms: [.macOS(.v14)],
            products: [.library(name: "LocalKit", targets: ["LocalKit"])],
            targets: [.target(name: "LocalKit")]
        )
    """)
    write_file(pkg / "Sources/LocalKit/Shout.swift", """
        public func shout(_ text: String) -> String {
            text.uppercased() + "!"
        }
    """)

    # A framework project: shared by the app project through the workspace's build products.
    core = Project("Core", base / "Core")
    write_file(base / "Core/Sources/Core.swift", """
        import LocalKit

        public struct Core: Sendable {
            public init() {}

            public func message() -> String {
                shout("core")
            }
        }
    """)
    write_file(base / "Core/Sources/Counter.swift", """
        public struct Counter: Sendable {
            public private(set) var value = 0

            public init() {}

            public mutating func increment() {
                value += 1
            }
        }
    """)
    core.project_settings = {"SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0", "SWIFT_VERSION": "6.0"}
    core.local_packages = ["../LocalKit"]
    core.target(
        name="Core", kind="framework",
        sources=["Sources/Core.swift", "Sources/Counter.swift"],
        package_products=[("LocalKit", "LocalKit")],
        settings={**COMMON, "PRODUCT_BUNDLE_IDENTIFIER": "dev.swiftide.fixture.core", "PRODUCT_NAME": "$(TARGET_NAME)",
                  "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0", "DEFINES_MODULE": "YES",
                  "BUILD_LIBRARY_FOR_DISTRIBUTION": "NO", "SKIP_INSTALL": "YES"},
    )
    core.write()

    # The app project: two targets (app + generated-sources helper app is not needed; one app) that
    # imports the framework of the other project, a local package, and has a generated source file.
    app = Project("App", base / "App")
    write_file(base / "App/Sources/main.swift", """
        import Core
        import LocalKit

        var counter = Counter()
        counter.increment()
        print(Core().message(), shout("app"), counter.value, Generated.stamp)
    """)
    app.project_settings = {"SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0", "SWIFT_VERSION": "6.0"}
    app.local_packages = ["../LocalKit"]
    app.target(
        name="App", kind="app",
        sources=["Sources/main.swift", "Generated/Generated.swift"],
        links_built_framework=["Core"],
        package_products=[("LocalKit", "LocalKit")],
        script={
            "output": "$(SRCROOT)/Generated/Generated.swift",
            "text": "mkdir -p \"$SRCROOT/Generated\"\nprintf 'enum Generated {\\n    static let stamp = \"generated\"\\n}\\n' > \"$SRCROOT/Generated/Generated.swift\"\n",
        },
        settings={**COMMON, "PRODUCT_BUNDLE_IDENTIFIER": "dev.swiftide.fixture.app", "PRODUCT_NAME": "$(TARGET_NAME)",
                  "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0",
                  "FRAMEWORK_SEARCH_PATHS": "$(inherited) $(BUILT_PRODUCTS_DIR)"},
    )
    app.write()

    ws = base / "Workspace.xcworkspace"
    ws.mkdir(parents=True, exist_ok=True)
    (ws / "contents.xcworkspacedata").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n'
        '   <FileRef\n      location = "group:App/App.xcodeproj">\n   </FileRef>\n'
        '   <FileRef\n      location = "group:Core/Core.xcodeproj">\n   </FileRef>\n'
        '   <FileRef\n      location = "group:LocalKit">\n   </FileRef>\n'
        '</Workspace>\n'
    )


if __name__ == "__main__":
    mac_app()
    ios_app()
    workspace()
    print("fixtures written under", ROOT)

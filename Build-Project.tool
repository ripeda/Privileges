#!/usr/bin/env python3

import os
import sys
import time
import argparse
import subprocess
import threading

from pathlib import Path



PROJECT_SOURCE: str = "source/Privileges.xcodeproj"
PROJECT_SCHEME: str = "Privileges"

DAEMON_SOURCE: str = "source/PrivilegesWatchdog"

APP_BUILD_PATH: str = "products/Application"
PKG_BUILD_PATH: str = "products/Package"

INSTALL_SCRIPTS_PATH:   str = "source/Scripts (Install)"
UNINSTALL_SCRIPTS_PATH: str = "source/Scripts (Uninstall)"
COMPONENT_PATH:         str = "source/component.plist"
MENUBAR_ICONS_PATH:     str = "source/Support Icons"


class GeneratePrivileges:


    def __init__(self, app_codesign_identity: str, pkg_codesign_identity: str) -> None:
        """
        Initializes the build process.
        """
        os.chdir(Path(__file__).parent)

        self._version: str = self._fetch_version()
        self._app_codesign_identity: str = "-" if app_codesign_identity is None else app_codesign_identity
        self._pkg_codesign_identity: str = pkg_codesign_identity

        print(f"Building Privileges {self._version}...")
        self._build_application()
        self._build_launch_daemon()
        self._build_package()


    def _fetch_version(self) -> str:
        """
        Fetches the version from the Info.plist file.
        """

        return "1.5.8"


    def _build_application(self) -> None:
        """
        Invokes xcodebuild to build the application.
            'xcodebuild build -project ./source/Privileges.xcodeproj -scheme Privileges -derivedDataPath ./products'
        """

        if Path(APP_BUILD_PATH).exists():
            subprocess.run(["rm", "-rf", APP_BUILD_PATH])

        threads = []
        identity = self._app_codesign_identity

        for variant in ["Debug", "Release"]:

            def _build(self, variant) -> None:
                print(f"APP: Building {variant} variant...")
                result = subprocess.run(["/usr/bin/xcodebuild", "build", "-project", PROJECT_SOURCE, "-scheme", PROJECT_SCHEME, "-derivedDataPath", APP_BUILD_PATH + "/" + variant, "-configuration", variant], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if result.returncode != 0:
                    print("Failed to build application.")
                    print(result.stdout)
                    if result.stderr:
                        print(result.stderr)
                    sys.exit(1)

                # app Menubar icon
                for icon in Path(MENUBAR_ICONS_PATH).glob("*.icns"):
                    subprocess.run(["cp", icon, Path(APP_BUILD_PATH, variant, "Build", "Products", variant, "Privileges.app", "Contents", "Resources", icon.name)])

                print(f"APP: Signing {variant} variant...")
                apps_to_sign = [
                    "Privileges.app",
                    "Privileges.app/Contents/Resources/PrivilegesCLI",
                    "Privileges.app/Contents/XPCServices/PrivilegesXPC.xpc",
                    "Privileges.app/Contents/PlugIns/PrivilegesTile.docktileplugin",
                    "Privileges.app/Contents/XPCServices/PrivilegesXPC.xpc/Contents/Library/LaunchServices/com.ripeda.privileges.helper",
                ]
                for app in apps_to_sign:
                    print(f"APP:   Signing {app if '/' not in app else app.split('/')[-1]}...")
                    result = subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, Path(APP_BUILD_PATH, variant, "Build", "Products", variant, app)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    if result.returncode != 0:
                        print("Failed to codesign application.")
                        print(result.stdout)
                        if result.stderr:
                            print(result.stderr)
                        sys.exit(1)

            thread = threading.Thread(target=_build, args=(self, variant))
            thread.start()
            threads.append(thread)

        while any(thread.is_alive() for thread in threads):
            time.sleep(1)


    def _build_package(self) -> None:
        """
        Prepares package enviroment and invokes pkgbuild to build the package.
        """

        if Path(PKG_BUILD_PATH).exists():
            subprocess.run(["rm", "-rf", PKG_BUILD_PATH])

        # Prepare scripts
        for script in ["preinstall", "postinstall"]:
            subprocess.run(["chmod", "+x", Path(INSTALL_SCRIPTS_PATH, script)])
        subprocess.run(["chmod", "+x", Path(UNINSTALL_SCRIPTS_PATH, "preinstall")])

        print("PKG: Building uninstaller...")
        Path(PKG_BUILD_PATH).mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            ["/usr/bin/pkgbuild",
             "--scripts", UNINSTALL_SCRIPTS_PATH,
             "--identifier", "com.ripeda.privileges-client-uninstaller",
             "--version", self._version,
             "--install-location", "/", Path(PKG_BUILD_PATH, "Uninstall-RIPEDA-Privileges-Client.pkg"),
             "--nopayload"
             ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode != 0:
            print("Failed to build uninstaller.")
            print(result.stdout)
            if result.stderr:
                print(result.stderr)
            sys.exit(1)

        # productsign
        if self._pkg_codesign_identity is not None:
            print("PKG: Signing uninstaller...")
            result = subprocess.run(["/usr/bin/productsign", "--sign", self._pkg_codesign_identity, Path(PKG_BUILD_PATH, "Uninstall-RIPEDA-Privileges-Client.pkg"), Path(PKG_BUILD_PATH, "Uninstall-RIPEDA-Privileges-Client-signed.pkg")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode != 0:
                print("Failed to sign uninstaller.")
                print(result.stdout)
                if result.stderr:
                    print(result.stderr)
                sys.exit(1)
            subprocess.run(["rm", Path(PKG_BUILD_PATH, "Uninstall-RIPEDA-Privileges-Client.pkg")])
            subprocess.run(["mv", Path(PKG_BUILD_PATH, "Uninstall-RIPEDA-Privileges-Client-signed.pkg"), Path(PKG_BUILD_PATH, "Uninstall-RIPEDA-Privileges-Client.pkg")])


        for variant in ["Debug", "Release"]:
            print(f"PKG: Building {variant} variant...")

            # Create package directory structure
            Path(PKG_BUILD_PATH, variant, "Applications").mkdir(parents=True, exist_ok=True)
            Path(PKG_BUILD_PATH, variant, "Library/LaunchAgents").mkdir(parents=True, exist_ok=True)
            Path(PKG_BUILD_PATH, variant, "Library/Application Support/RIPEDA/RIPEDA Client").mkdir(parents=True, exist_ok=True)

            # Copy application to package directory
            subprocess.run(["cp", "-R", Path(APP_BUILD_PATH, variant, "Build", "Products", variant, "Privileges.app"), Path(PKG_BUILD_PATH, variant, "Applications")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            # Copy launch daemon to package directory from RIPEDA-Privileges-Watchdog
            subprocess.run(["cp", Path(DAEMON_SOURCE, "com.ripeda.privileges-watchdog.auto-start.plist"), Path(PKG_BUILD_PATH, variant, "Library/LaunchAgents")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            # Copy uninstaller to package directory
            subprocess.run(["cp", Path(PKG_BUILD_PATH, "Uninstall-RIPEDA-Privileges-Client.pkg"), Path(PKG_BUILD_PATH, variant, "Library/Application Support/RIPEDA/RIPEDA Client")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            # Build package
            result = subprocess.run(
                ["/usr/bin/pkgbuild",
                 "--component-plist", COMPONENT_PATH,
                 "--root", Path(PKG_BUILD_PATH, variant),
                 "--scripts", INSTALL_SCRIPTS_PATH,
                 "--identifier", "com.ripeda.privileges-client-installer",
                 "--version", self._version,
                 "--install-location", "/", Path(PKG_BUILD_PATH, variant, f"../Install-RIPEDA-Privileges-Client-{variant}.pkg")
                ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode != 0:
                print("Failed to build package.")
                print(result.stdout)
                if result.stderr:
                    print(result.stderr)
                sys.exit(1)

            # productsign
            if self._pkg_codesign_identity is not None:
                print(f"PKG: Signing {variant} variant...")
                result = subprocess.run(["/usr/bin/productsign", "--sign", self._pkg_codesign_identity, Path(PKG_BUILD_PATH, variant, f"../Install-RIPEDA-Privileges-Client-{variant}.pkg"), Path(PKG_BUILD_PATH, variant, f"../Install-RIPEDA-Privileges-Client-{variant}-signed.pkg")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if result.returncode != 0:
                    print("Failed to sign package.")
                    print(result.stdout)
                    if result.stderr:
                        print(result.stderr)
                    sys.exit(1)
                subprocess.run(["rm", Path(PKG_BUILD_PATH, variant, f"../Install-RIPEDA-Privileges-Client-{variant}.pkg")])
                subprocess.run(["mv", Path(PKG_BUILD_PATH, variant, f"../Install-RIPEDA-Privileges-Client-{variant}-signed.pkg"), Path(PKG_BUILD_PATH, variant, f"../Install-RIPEDA-Privileges-Client-{variant}.pkg")])


    def _build_launch_daemon(self) -> None:
        """
        Call pyinstaller to build the launch daemon.
        """

        if Path(DAEMON_SOURCE, "dist").exists():
            subprocess.run(["rm", "-rf", Path(DAEMON_SOURCE, "dist")])

        print("LA:  Building launch agent...")
        result = subprocess.run(["pyinstaller", Path(DAEMON_SOURCE, "watch.spec"), "--distpath", Path(DAEMON_SOURCE, "dist")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode != 0:
            print("Failed to build launch daemon.")
            print(result.stdout)
            if result.stderr:
                print(result.stderr)
            sys.exit(1)

        print("LA:  Signing launch agent...")
        result = subprocess.run(["/usr/bin/codesign", "--force", "--sign", self._app_codesign_identity, Path(DAEMON_SOURCE, "dist", "RIPEDA-Privileges-Watchdog")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode != 0:
            print("Failed to codesign launch daemon.")
            print(result.stdout)
            if result.stderr:
                print(result.stderr)
            sys.exit(1)

        for variant in ["Debug", "Release"]:
            # copy to each app bundle
            subprocess.run(["cp", "-R", Path(DAEMON_SOURCE, "dist", "RIPEDA-Privileges-Watchdog"), Path(APP_BUILD_PATH, variant, "Build", "Products", variant, "Privileges.app", "Contents", "Resources", "RIPEDA-Privileges-Watchdog")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Builds Privileges.")
    parser.add_argument("--app_signing_identity", type=str, help="App Signing identity")
    parser.add_argument("--pkg_signing_identity", type=str, help="PKG Signing identity")
    args = parser.parse_args()

    GeneratePrivileges(args.app_signing_identity, args.pkg_signing_identity)


#!/usr/bin/env python3

import os
import sys
import time
import argparse
import threading
import subprocess
import macos_pkg_builder

from pathlib import Path



PROJECT_SOURCE: str = "source/Privileges.xcodeproj"
PROJECT_SCHEME: str = "Privileges"

APP_BUILD_PATH: str = "products/Application"
PKG_BUILD_PATH: str = "products/Package"

INSTALL_SCRIPTS_PATH:   str = "source/Scripts (Install)"
UNINSTALL_SCRIPTS_PATH: str = "source/Scripts (Uninstall)"
COMPONENT_PATH:         str = "source/component.plist"
MENUBAR_ICONS_PATH:     str = "source/Support Icons"
LAUNCH_AGENTS:          str = "source/Support LaunchAgents"


NOTARIZATION_TEAM_ID:  str = None
NOTARIZATION_APPLE_ID: str = None
NOTARIZATION_PASSWORD: str = None


class Notarize:

    def __init__(self, file: str) -> None:
        self._file     = file
        self._apple_id = NOTARIZATION_APPLE_ID
        self._password = NOTARIZATION_PASSWORD
        self._team_id  = NOTARIZATION_TEAM_ID


    def sign(self) -> None:
        if any([self._apple_id is None, self._password is None, self._team_id is None]):
            print("Error: Notarization credentials not provided, skipping")
            return

        arguments = [
            "xcrun", "notarytool", "submit", self._file, "--apple-id", self._apple_id, "--password", self._password, "--team-id", self._team_id, "--wait"
        ]
        result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode != 0:
            print(f"Error notarizing: {result.stderr.decode('utf-8')}")
            sys.exit(1)
        if "status: Accepted" not in result.stdout.decode("utf-8"):
            print(f"Error notarizing: {self._fetch_error(self._decode_id_from_stdout(result.stdout.decode('utf-8')))}")
            sys.exit(1)


    def _decode_id_from_stdout(self, stdout: str) -> str:
        """
        Extract the ID from the stdout
        """
        for line in stdout.split("\n"):
            if line.startswith("  id: "):
                return line[6:]
        return None


    def _fetch_error(self, id: str) -> str:
        result = subprocess.run(["xcrun", "notarytool", "log", id, "--apple-id", self._apple_id, "--password", self._password, "--team-id", self._team_id], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode != 0:
            return result.stderr.decode("utf-8")
        return result.stdout.decode("utf-8")


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
        self._build_package()


    def _fetch_version(self) -> str:
        """
        Fetches the version from the Info.plist file.
        """
        with open(Path(f"{PROJECT_SOURCE}/project.pbxproj"), "r") as file:
            # Find 'MARKETING_VERSION = '
            for line in file:
                if "MARKETING_VERSION = " in line:
                    # Remove 'MARKETING_VERSION = '
                    version = line.replace("MARKETING_VERSION = ", "")
                    # Remove ';'
                    version = version.replace(";", "")
                    # Remove whitespaces
                    version = version.strip()
                    # Remove quotes
                    version = version.replace("\"", "")
                    # Return version
                    return version

        return "1.0.0"


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
                    "Privileges.app/Contents/Resources/PrivilegesMenubar",
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

        Path(PKG_BUILD_PATH).mkdir(parents=True, exist_ok=True)

        print("PKG: Building uninstaller...")
        pkg_obj = macos_pkg_builder.Packages(
            pkg_output=Path(PKG_BUILD_PATH, "Uninstall-RIPEDA-Privileges-Client.pkg"),
            pkg_bundle_id="com.ripeda.privileges-client-uninstaller",
            pkg_version=self._version,
            pkg_preinstall_script=Path(UNINSTALL_SCRIPTS_PATH, "preinstall"),
            **({"pkg_signing_identity": self._pkg_codesign_identity} if self._pkg_codesign_identity is not None else {})
        )
        if pkg_obj.build() is False:
            print("Error creating uninstall pkg.")
            sys.exit(1)

        for variant in ["Debug", "Release"]:
            print(f"PKG: Building {variant} variant...")

            pkg_obj = macos_pkg_builder.Packages(
                pkg_output=Path(PKG_BUILD_PATH, f"Install-RIPEDA-Privileges-Client-{variant}.pkg"),
                pkg_bundle_id="com.ripeda.privileges-client-installer",
                pkg_version=self._version,
                pkg_preinstall_script=Path(INSTALL_SCRIPTS_PATH, "preinstall"),
                pkg_postinstall_script=Path(INSTALL_SCRIPTS_PATH, "postinstall"),
                pkg_file_structure={
                    Path(APP_BUILD_PATH, variant, "Build", "Products", variant, "Privileges.app"): "/Applications/Privileges.app",
                    Path(LAUNCH_AGENTS, "com.ripeda.privileges-menubar.plist"): "/Library/LaunchAgents/com.ripeda.privileges-menubar.plist",
                    Path(PKG_BUILD_PATH, "Uninstall-RIPEDA-Privileges-Client.pkg"): "/Library/Application Support/RIPEDA/RIPEDA Client/Uninstall-RIPEDA-Privileges-Client.pkg",
                },
                pkg_allow_relocation=False,
                **({"pkg_signing_identity": self._pkg_codesign_identity} if self._pkg_codesign_identity is not None else {})
            )
            if pkg_obj.build() is False:
                print(f"Error creating install pkg for {variant} variant.")
                sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Builds Privileges.")
    parser.add_argument("--app_signing_identity", type=str, help="App Signing identity")
    parser.add_argument("--pkg_signing_identity", type=str, help="PKG Signing identity")
    parser.add_argument("--notarize_apple_id", type=str, help="Apple ID")
    parser.add_argument("--notarize_password", type=str, help="Password")
    parser.add_argument("--notarize_team_id", type=str, help="Team ID")

    args = parser.parse_args()

    NOTARIZATION_APPLE_ID = args.notarize_apple_id
    NOTARIZATION_PASSWORD = args.notarize_password
    NOTARIZATION_TEAM_ID  = args.notarize_team_id

    GeneratePrivileges(args.app_signing_identity, args.pkg_signing_identity)


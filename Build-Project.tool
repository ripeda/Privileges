#!/usr/bin/env python3

import os
import sys
import time
import argparse
import threading
import subprocess
import macos_pkg_builder
import mac_signing_buddy

from pathlib import Path


PROJECT_SOURCE: str = "source/Privileges.xcodeproj"
PROJECT_SCHEME: str = "Privileges"

APP_BUILD_PATH: str = "products/Application"
PKG_BUILD_PATH: str = "products/Package"

INSTALL_SCRIPTS_PATH:   str = "source/Scripts (Install)"
UNINSTALL_SCRIPTS_PATH: str = "source/Scripts (Uninstall)"
MENUBAR_ICONS_PATH:     str = "source/Support Icons"
LAUNCH_AGENTS:          str = "source/Support LaunchAgents"


NOTARIZATION_TEAM_ID:  str = None
NOTARIZATION_APPLE_ID: str = None
NOTARIZATION_PASSWORD: str = None


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
            subprocess.run(["/bin/rm", "-rf", APP_BUILD_PATH])

        for variant in ["Debug", "Release"]:
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
                subprocess.run(["/bin/cp", icon, Path(APP_BUILD_PATH, variant, "Build", "Products", variant, "Privileges.app", "Contents", "Resources", icon.name)])

            print(f"APP: Signing {variant} variant...")
            for resource in [
                "XPCServices/PrivilegesXPC.xpc/Contents/Library/LaunchServices/com.ripeda.privileges.helper",
                "Resources/PrivilegesMenubar",
                "Resources/PrivilegesCLI"
            ]:
                mac_signing_buddy.Sign(file=Path(APP_BUILD_PATH, variant, "Build", "Products", variant, "Privileges.app", "Contents", resource).resolve(), identity=self._app_codesign_identity).sign()
            mac_signing_buddy.Sign(file=Path(APP_BUILD_PATH, variant, "Build", "Products", variant, "Privileges.app").resolve(), identity=self._app_codesign_identity).sign()
            print(f"APP: Notarizing {variant} variant...")
            mac_signing_buddy.Notarize(file=Path(APP_BUILD_PATH, variant, "Build", "Products", variant, "Privileges.app").resolve(), apple_id=NOTARIZATION_APPLE_ID, password=NOTARIZATION_PASSWORD, team_id=NOTARIZATION_TEAM_ID).sign()


    def _build_package(self) -> None:
        """
        Prepares package enviroment and invokes pkgbuild to build the package.
        """

        if Path(PKG_BUILD_PATH).exists():
            subprocess.run(["/bin/rm", "-rf", PKG_BUILD_PATH])

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

            print(f"PKG: Notarizing {variant} variant...")
            mac_signing_buddy.Notarize(file=Path(PKG_BUILD_PATH, f"Install-RIPEDA-Privileges-Client-{variant}.pkg").resolve(), apple_id=NOTARIZATION_APPLE_ID, password=NOTARIZATION_PASSWORD, team_id=NOTARIZATION_TEAM_ID).sign()


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


#!/usr/bin/env python3

import sys
import argparse
import subprocess
import plistlib

from pathlib import Path



PROJECT_SOURCE: str = "source/Privileges.xcodeproj"
PROJECT_SCHEME: str = "Privileges"

APP_BUILD_PATH: str = "products/Application"
PKG_BUILD_PATH: str = "products/Package"

SCRIPTS_PATH: str = "source/Scripts"


class GeneratePrivileges:


    def __init__(self) -> None:
        """
        Initializes the build process.
        """

        self._version: str = self._fetch_version()

        print(f"Building Privileges {self._version}...")
        self._build_application()
        self._build_package()


    def _fetch_version(self) -> str:
        """
        Fetches the version from the Info.plist file.
        """

        return "1.0.0"

        with open("source/Privileges/Info.plist", "rb") as file:
            plist = plistlib.load(file)
            return plist["CFBundleShortVersionString"]


    def _build_application(self) -> None:
        """
        Invokes xcodebuild to build the application.
            'xcodebuild build -project ./source/Privileges.xcodeproj -scheme Privileges -derivedDataPath ./products'
        """

        if Path(APP_BUILD_PATH).exists():
            subprocess.run(["rm", "-rf", APP_BUILD_PATH])

        for variant in ["Debug", "Release"]:
            print(f"APP: Building {variant} variant...")
            result = subprocess.run(["/usr/bin/xcodebuild", "build", "-project", PROJECT_SOURCE, "-scheme", PROJECT_SCHEME, "-derivedDataPath", APP_BUILD_PATH, "-configuration", variant], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode != 0:
                print("Failed to build application.")
                print(result.stdout)
                if result.stderr:
                    print(result.stderr)
                sys.exit(1)


    def _build_package(self) -> None:
        """
        Prepares package enviroment and invokes pkgbuild to build the package.
        """

        if Path(PKG_BUILD_PATH).exists():
            subprocess.run(["rm", "-rf", PKG_BUILD_PATH])

        # Prepare scripts
        for script in ["preinstall", "postinstall"]:
            subprocess.run(["chmod", "+x", Path(SCRIPTS_PATH, script)])

        for variant in ["Debug", "Release"]:
            print(f"PKG: Building {variant} variant...")

            # Create package directory structure
            Path(PKG_BUILD_PATH, variant, "Applications").mkdir(parents=True, exist_ok=True)

            # Copy application to package directory
            subprocess.run(["cp", "-R", Path(APP_BUILD_PATH, "Build", "Products", variant, "Privileges.app"), Path(PKG_BUILD_PATH, variant, "Applications")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            # Build package
            result = subprocess.run(["/usr/bin/pkgbuild", "--root", Path(PKG_BUILD_PATH, variant), "--scripts", SCRIPTS_PATH, "--identifier", "com.github.SAP.macOS.Privileges", "--version", self._version, "--install-location", "/", Path(PKG_BUILD_PATH, variant, f"../RIPEDA-Privileges-{variant}.pkg")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode != 0:
                print("Failed to build package.")
                print(result.stdout)
                if result.stderr:
                    print(result.stderr)
                sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Builds Privileges.")
    parser.parse_args()

    GeneratePrivileges()


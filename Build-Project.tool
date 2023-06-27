#!/usr/bin/env python3

import sys
import time
import argparse
import subprocess
import plistlib
import threading

from pathlib import Path



PROJECT_SOURCE: str = "source/Privileges.xcodeproj"
PROJECT_SCHEME: str = "Privileges"

DAEMON_SOURCE: str = "source/PrivilegesWatchdog"

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
        self._build_launch_daemon()
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

        threads = []

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
            subprocess.run(["chmod", "+x", Path(SCRIPTS_PATH, script)])

        for variant in ["Debug", "Release"]:
            print(f"PKG: Building {variant} variant...")

            # Create package directory structure
            Path(PKG_BUILD_PATH, variant, "Applications").mkdir(parents=True, exist_ok=True)
            Path(PKG_BUILD_PATH, variant, "Library/LaunchAgents").mkdir(parents=True, exist_ok=True)

            # Copy application to package directory
            subprocess.run(["cp", "-R", Path(APP_BUILD_PATH, variant, "Build", "Products", variant, "Privileges.app"), Path(PKG_BUILD_PATH, variant, "Applications")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            # Copy launch daemon to package directory from RIPEDA-Privileges-Watchdog
            subprocess.run(["cp", Path(DAEMON_SOURCE, "com.ripeda.privileges-watchdog.auto-start.plist"), Path(PKG_BUILD_PATH, variant, "Library/LaunchAgents")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            # Build package
            result = subprocess.run(["/usr/bin/pkgbuild", "--root", Path(PKG_BUILD_PATH, variant), "--scripts", SCRIPTS_PATH, "--identifier", "com.github.SAP.macOS.Privileges", "--version", self._version, "--install-location", "/", Path(PKG_BUILD_PATH, variant, f"../RIPEDA-Privileges-Client-{variant}.pkg")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode != 0:
                print("Failed to build package.")
                print(result.stdout)
                if result.stderr:
                    print(result.stderr)
                sys.exit(1)


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

        for variant in ["Debug", "Release"]:
            # copy to each app bundle
            subprocess.run(["cp", "-R", Path(DAEMON_SOURCE, "dist", "RIPEDA-Privileges-Watchdog"), Path(APP_BUILD_PATH, variant, "Build", "Products", variant, "Privileges.app", "Contents", "Resources", "RIPEDA-Privileges-Watchdog")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Builds Privileges.")
    parser.parse_args()

    GeneratePrivileges()


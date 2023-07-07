"""
This script will be fired up at Launch Time as a LaunchDaemon.
Every minute, we'll check the current status of the user's privileges.
If they're admin, start a count down timer to demote them.
If they manually demote themselves, stop the timer.
"""

import os
import enum
import time
import logging
import plistlib
import threading
import subprocess

from pathlib import Path


CLI_PATH: str = "/Applications/Privileges.app/Contents/Resources/PrivilegesCLI"
CONFIG_PATH: str = "/Library/Managed Preferences/com.ripeda.privileges.plist"
TIMER_LENGTH: float = 60.0 * 10.0 # Default 10 minutes
GLOBAL_TIMER: threading.Timer = None
GLOBAL_TIME:  float = 0.0


class PrivilegesMode(enum.Enum):
    ADMIN    = "admin"
    STANDARD = "standard"
    UNKNOWN  = "unknown"


class PrivilegesWatchdog:

    def __init__(self) -> None:
        self._initialize_logging()
        logging.info("Privileges Watchdog started")

        if not Path(CLI_PATH).exists():
            raise Exception(f"Privileges CLI not found at {CLI_PATH}")

        self._fetch_config()
        self._start()


    def _fetch_config(self) -> None:
        """
        Fetch the config from the MDM
        """
        if not Path(CONFIG_PATH).exists():
            return
        config = plistlib.load(open(CONFIG_PATH, "rb"))
        if "TimerLength" in config:
            global TIMER_LENGTH
            TIMER_LENGTH = config["TimerLength"]
            logging.info(f"Timer length set to {TIMER_LENGTH} seconds")


    def _start(self) -> None:
        while True:
            self._check_privileges()
            time.sleep(60.0)


    def _check_privileges(self) -> None:
        """
        Check the current privileges mode
        """
        current_privileges = self._get_current_privileges()

        global GLOBAL_TIMER
        if current_privileges == PrivilegesMode.ADMIN:
            if GLOBAL_TIMER is None:
                logging.info(f"User is admin, starting timer: {TIMER_LENGTH} seconds")
                self._start_timer()
                return
            global GLOBAL_TIME
            logging.info(f"Time remaining: {round(TIMER_LENGTH - (time.time() - GLOBAL_TIME))} seconds")
            return

        if GLOBAL_TIMER is not None:
            logging.info("User is not admin, stopping timer")
            GLOBAL_TIMER.cancel()
            GLOBAL_TIMER = None
            GLOBAL_TIME = 0.0
            return


    def _get_current_privileges(self) -> str:
        """
        Check if admin or standard user

        For some reason PrivilegesCLI outputs to STDERR...
        """
        result = subprocess.run([CLI_PATH, "--status"], capture_output=True)
        if result.returncode != 0:
            return PrivilegesMode.UNKNOWN

        return PrivilegesMode.ADMIN if "has admin rights" in result.stderr.decode("utf-8") else PrivilegesMode.STANDARD


    def _demote_user(self) -> None:
        """
        Demote the user
        """
        logging.info("Demoting user")
        subprocess.run([CLI_PATH, "--remove"])

        global GLOBAL_TIMER
        GLOBAL_TIMER = None

        global GLOBAL_TIME
        GLOBAL_TIME = 0.0


    def _promote_user(self) -> None:
        """
        Promote the user

        This should never be called, but just in case...
        """
        logging.info("Promoting user")
        subprocess.run([CLI_PATH, "--add"])


    def _start_timer(self) -> None:
        """
        Start the timer
        """
        global GLOBAL_TIMER
        GLOBAL_TIMER = threading.Timer(TIMER_LENGTH, self._demote_user)
        GLOBAL_TIMER.start()

        global GLOBAL_TIME
        GLOBAL_TIME = time.time()


    def _initialize_logging(self) -> None:
        path = Path(f"{'~' if os.geteuid() != 0 else ''}/Library/Logs/RIPEDA_Privileges_Watchdog.log").expanduser()
        if path.exists():
            subprocess.run(["rm", f"{path}.old"])
            subprocess.run(["mv", path, f"{path}.old"])

        logging.basicConfig(
            level=logging.INFO,
            format="[%(asctime)s] [%(filename)-22s] [%(levelname)-8s] [%(lineno)-3d]: %(message)s",
            handlers=[
                logging.FileHandler(path),
                logging.StreamHandler()
            ]
        )

if __name__ == "__main__":
    PrivilegesWatchdog()
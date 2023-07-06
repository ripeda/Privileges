"""
This script will be fired up at Launch Time as a LaunchDaemon.
Every minute, we'll check the current status of the user's privileges.
If they're admin, start a count down timer to demote them.
If they manually demote themselves, stop the timer.
"""

import subprocess
import threading
import enum
import time
import logging
import os
from pathlib import Path

CLI_PATH: str = "/Applications/Privileges.app/Contents/Resources/PrivilegesCLI"
TIMER_LENGTH: float = 60.0 * 10.0 # 10 minutes
GLOBAL_TIMER: threading.Timer = None


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

        self._start()


    def _start(self) -> None:
        while True:
            self._check_privileges()
            time.sleep(60.0)


    def _check_privileges(self) -> None:
        """
        Check the current privileges mode
        """
        current_privileges = self._get_current_privileges()

        logging.info(f"Current privileges: {current_privileges}")

        if current_privileges == PrivilegesMode.ADMIN:
            logging.info(f"User is admin, starting timer: {TIMER_LENGTH} seconds")
            self._start_timer()
            return

        global GLOBAL_TIMER
        if GLOBAL_TIMER is not None:
            logging.info("User is not admin, stopping timer")
            GLOBAL_TIMER.cancel()
            GLOBAL_TIMER = None
            return

        logging.info("No timer running")

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


    def _initialize_logging(self) -> None:
        logging.basicConfig(
            level=logging.INFO,
            format="[%(asctime)s] [%(filename)-22s] [%(levelname)-8s] [%(lineno)-3d]: %(message)s",
            handlers=[
                logging.FileHandler(Path(f"{'~' if os.geteuid() != 0 else ''}/Library/Logs/RIPEDA_Privileges_Watchdog.log").expanduser()),
                logging.StreamHandler()
            ]
        )

if __name__ == "__main__":
    PrivilegesWatchdog()
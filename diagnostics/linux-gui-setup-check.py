#!/usr/bin/python3
"""Exercise the GTK setup window against a fixture backend. Run under xvfb-run."""
import importlib.util
import os
from pathlib import Path
import signal
import sys
import tempfile
import time


kit = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("installer", kit / "tools/altium-linux-installer.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def click(window, title):
    widget = window.actions.get_first_child()
    while widget:
        if isinstance(widget, installer.Gtk.Button) and widget.get_label() == title:
            assert widget.get_sensitive(), title
            widget.emit("clicked")
            return
        widget = widget.get_next_sibling()
    raise AssertionError(f"Missing action {title}")


def check(directory):
    setup = directory / "install.sh"
    setup.write_text(r"""
set -eu
emit() { local field; printf '@@sw'; for field do printf '\t%s' "$field"; done; printf '\n'; }
emit welcome 0 0 '' v1.5.15
read -r answer; [ "$answer" = install ]
emit choose "$TEST_GUI_INSTALLER" 'Choose a setup file.'
read -r answer; [ "$answer" = "$TEST_GUI_INSTALLER" ]
emit stage wine 'preparing Wine'
printf '\033[34mTest log line\033[0m\n'
emit stage altium 'opening the Altium installer'
emit wait 'Install Altium' 'Continue in the vendor window.' 'Waiting for setup.'
sleep 0.8
if [ ! -e "$TEST_GUI_RETRY" ]; then
    touch "$TEST_GUI_RETRY"
    emit failed 'installing Altium'
    exit 1
fi
emit finished 'Setup is complete.'
""")
    executable = directory / "Altium Designer.exe"
    executable.touch()
    os.environ.update(TEST_GUI_INSTALLER=str(executable), TEST_GUI_RETRY=str(directory / "retry"))
    window = installer.Installer(setup, directory / "prefix", [])
    expectation = iter(("welcome", "choose", "waiting", "failed", "welcome", "choose", "waiting", "finished"))
    pending = next(expectation)
    failure = None
    remaining = 150

    def poll():
        nonlocal pending, failure, remaining
        try:
            remaining -= 1
            if remaining == 0:
                raise AssertionError(f"Timed out waiting for {pending}, current page {window.page}")
            if window.page[0] != pending:
                return True
            if pending == "welcome":
                click(window, "Clean Install")
            elif pending == "choose":
                click(window, "Continue")
            elif pending == "waiting":
                assert window.status == "Waiting for setup."
                window.window.close()
                dialog = next(dialog for dialog in installer.Gtk.Window.list_toplevels()
                              if isinstance(dialog, installer.Gtk.MessageDialog)
                              and dialog.get_transient_for() is window.window)
                assert "Close the Altium installer window" in dialog.get_property("secondary-text")
                dialog.emit("response", installer.Gtk.ResponseType.CLOSE)
                assert not window.quitting
            elif pending == "failed":
                assert window.terminal.get_active()
                log = window.log.get_text(window.log.get_start_iter(), window.log.get_end_iter(), True)
                assert "Test log line" in log and "\x1b" not in log
                click(window, "Try Again")
            elif pending == "finished":
                assert window.page[1] == "Setup is complete."
                window.quit()
                return False
            pending = next(expectation)
            return True
        except Exception as error:
            failure = error
            window.quit()
            return False

    installer.GLib.timeout_add(100, poll)
    window.run([sys.argv[0]])
    if failure:
        raise failure


def process_running(pid):
    if pid is None:
        return False
    try:
        state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
    except (FileNotFoundError, ProcessLookupError):
        return False
    return state not in ("Z", "X")


def check_cancellation(directory):
    setup = directory / "cancel.sh"
    setup.write_text(r"""
set -eu
trap 'touch "$TEST_GUI_TERM"; exit 130' TERM
bash -c 'trap "" TERM; printf "%s\n" "$BASHPID" > "$TEST_GUI_CHILD"; exec sleep 60' &
printf '@@sw\tstage\twine\tpreparing Wine\n'
printf '@@sw\twait\tInstall Altium\tFixture waiting.\tWaiting for setup.\n'
wait
""")
    child_file, term_file = directory / "child.pid", directory / "terminated"
    os.environ.update(TEST_GUI_CHILD=str(child_file), TEST_GUI_TERM=str(term_file))
    window = installer.Installer(setup, directory / "cancel-root", [])
    descendant = None
    failure = None
    expired = False

    def cancel():
        nonlocal descendant, failure
        if window.page[0] != "waiting" or not child_file.exists():
            return True
        try:
            descendant = int(child_file.read_text())
            assert process_running(descendant), "Cancellation fixture child exited too early"
            window.window.close()
            dialog = next(dialog for dialog in installer.Gtk.Window.list_toplevels()
                          if isinstance(dialog, installer.Gtk.MessageDialog)
                          and dialog.get_transient_for() is window.window)
            dialog.emit("response", installer.Gtk.ResponseType.ACCEPT)
        except Exception as error:
            failure = error
            window.quit()
        return False

    def watchdog():
        nonlocal expired, failure
        expired = True
        failure = AssertionError("The installer did not exit after cancellation")
        window.quit()
        return False

    cancellation = installer.GLib.timeout_add(100, cancel)
    timeout = installer.GLib.timeout_add_seconds(8, watchdog)
    try:
        window.run([sys.argv[0]])
        if failure:
            raise failure
        assert term_file.exists(), "The fixture shell did not exit on TERM"
        assert descendant is not None, "The cancellation fixture was not exercised"
        deadline = time.monotonic() + 3
        while process_running(descendant) and time.monotonic() < deadline:
            time.sleep(0.05)
        assert not process_running(descendant), "The TERM-ignoring child survived cancellation"
    finally:
        if expired:
            if descendant is None:
                installer.GLib.source_remove(cancellation)
        else:
            installer.GLib.source_remove(timeout)
        try:
            if window.child is not None and window.child.poll() is None:
                os.killpg(window.child.pid, signal.SIGKILL)
                window.child.wait(timeout=2)
            if process_running(descendant):
                os.kill(descendant, signal.SIGKILL)
        except ProcessLookupError:
            pass


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="aw-linux-gui-check-") as temporary:
        directory = Path(temporary)
        check(directory)
        check_cancellation(directory)
    print("PASS: GTK setup path selection, vendor wait, error log, retry, finish, and cancellation.")

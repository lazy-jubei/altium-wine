#!/usr/bin/python3
"""GTK setup window for the Linux Altium Wine installer."""
import argparse
import os
from pathlib import Path
import re
import signal
import subprocess
import sys

try:
    import gi

    gi.require_version("Gdk", "4.0")
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gdk, Gio, GLib, Gtk, Pango
except (ImportError, ValueError):
    sys.exit("Linux graphical setup needs PyGObject and GTK4. Use install.sh --terminal for terminal setup.")


STEPS = (
    ("installer", "Choose the\nAltium installer", "Your Altium download"),
    ("wine", "Prepare Wine", "Automatic setup"),
    ("altium", "Install Altium", "In the Altium installer"),
    ("finish", "Finish", "Add to Applications"),
)
STYLE = b"""
.setup { background: #292929; color: #ededed; font-size: 13px; }
.setup headerbar { min-height: 28px; padding: 0 8px; background: #383838;
  border-bottom: 1px solid #181818; box-shadow: none; }
.setup headerbar .title { font-size: 13px; color: #c6c6c6; }
.setup headerbar windowcontrols button { min-height: 24px; min-width: 24px;
  padding: 0; color: #d0d0d0; }
.sidebar { background: #252525; border-right: 1px solid #414141; }
.brand, .current-step { font-weight: 700; }
.future-step, .muted { color: #b2b2b2; }
.subtitle { color: #ababab; font-size: 11px; }
.heading { font-size: 18px; font-weight: 700; }
.stage { font-size: 14px; font-weight: 700; }
.success { color: #55c779; }
.danger { color: #ff766b; }
.step-dot { border-radius: 50%; font-size: 10px; font-weight: 700; }
.step-dot.pending { border: 1px solid #626262; }
.step-dot.active { background: #008bff; color: #132641; }
.step-dot.done { background: #56c878; color: #173421; }
.step-dot.error { background: #ff766b; color: #4d2020; }
.divider { min-height: 1px; background: #414141; }
.setup .terminal-toggle { min-height: 29px; padding: 0 20px; color: #b7b7b7;
  background: transparent; border: none; box-shadow: none; }
.setup .terminal-toggle:hover { background: #313131; }
.terminal-log, .terminal-log text { background: #1c1c1c; color: #dedede; font-size: 11px; }
.setup button.action, .setup menubutton > button { border-radius: 6px; min-height: 26px;
  padding: 0 11px; background: #505050; color: #f3f3f3; border: none; box-shadow: none; }
.setup button.action:hover, .setup menubutton > button:hover { background: #606060; }
.setup button.primary { background: #1c61d4; }
.setup button.primary:hover { background: #3177e5; }
.setup button.action:disabled { opacity: 0.5; }
.setup entry { background: #353535; min-height: 26px; color: #f3f3f3; border-radius: 6px; }
.setup progressbar trough { min-height: 4px; border-radius: 3px; background: #484848; }
.setup progressbar progress { min-height: 4px; border-radius: 3px; background: #459bff; }
"""


def label(text, style=None, **kwargs):
    widget = Gtk.Label(label=text, xalign=0, **kwargs)
    if kwargs.get("wrap"):
        widget.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
    if style:
        for css_class in style.split():
            widget.add_css_class(css_class)
    return widget


def margin(widget, top, right, bottom, left):
    widget.set_margin_top(top)
    widget.set_margin_end(right)
    widget.set_margin_bottom(bottom)
    widget.set_margin_start(left)


def clear(box):
    child = box.get_first_child()
    while child is not None:
        box.remove(child)
        child = box.get_first_child()


def decode_field(field):
    return re.sub(r"\\([\\tn])", lambda match: {"\\": "\\", "t": "\t", "n": "\n"}[match[1]], field)


class Installer(Gtk.Application):
    def __init__(self, script, root, arguments):
        super().__init__(application_id="io.github.lazy_jubei.AltiumWineInstaller",
                         flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.script = script
        self.root = root
        self.arguments = arguments
        self.child = None
        self.output_watch = None
        self.pending = b""
        self.window = None
        self.chooser = None
        self.quitting = False
        self.restart_root = None

    def do_activate(self):
        if self.window:
            self.window.present()
            return
        Gtk.Settings.get_default().set_property("gtk-application-prefer-dark-theme", True)
        provider = Gtk.CssProvider()
        provider.load_from_data(STYLE)
        display = Gdk.Display.get_default()
        Gtk.StyleContext.add_provider_for_display(
            display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )
        self.window = Gtk.ApplicationWindow(application=self, title="Altium Designer Installer")
        self.window.add_css_class("setup")
        width, height = 900, 548
        monitor = display.get_monitors().get_item(0)
        if monitor is not None:
            size = monitor.get_geometry()
            width = min(width, max(590, size.width - 32))
            height = min(height, max(320, size.height - 40))
        self.window.set_default_size(width, height)
        self.window.set_size_request(590, 320)
        self.window.connect("close-request", self.request_close)
        header = Gtk.HeaderBar()
        header.set_title_widget(label("Altium Designer Installer", "title"))
        self.window.set_titlebar(header)

        layout = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        self.window.set_child(layout)
        sidebar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        sidebar.set_size_request(230, -1)
        sidebar.add_css_class("sidebar")
        layout.append(sidebar)
        self.steps = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        margin(self.steps, 22, 18, 16, 30)
        sidebar.append(self.steps)

        right = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        right.set_hexpand(True)
        layout.append(right)
        self.content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        margin(self.content, 26, 32, 20, 32)
        content_scroll = Gtk.ScrolledWindow(child=self.content, vexpand=True)
        content_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        right.append(content_scroll)
        right.append(self.divider())

        self.terminal = Gtk.ToggleButton()
        self.terminal.set_hexpand(True)
        terminal_label = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self.terminal_arrow = label("›")
        terminal_label.append(self.terminal_arrow)
        terminal_label.append(Gtk.Image.new_from_icon_name("utilities-terminal-symbolic"))
        terminal_label.append(label("Terminal"))
        self.terminal.set_child(terminal_label)
        self.terminal.add_css_class("flat")
        self.terminal.add_css_class("terminal-toggle")
        self.terminal.connect("toggled", self.toggle_terminal)
        terminal_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        terminal_row.append(self.terminal)
        right.append(terminal_row)
        self.log_view = Gtk.TextView(editable=False, cursor_visible=False, monospace=True)
        self.log_view.add_css_class("terminal-log")
        self.log_view.set_left_margin(10)
        self.log_view.set_right_margin(10)
        self.log_view.set_top_margin(8)
        self.log_view.set_bottom_margin(8)
        self.log = self.log_view.get_buffer()
        self.log_end = self.log.create_mark(None, self.log.get_end_iter(), False)
        self.log_scroll = Gtk.ScrolledWindow(child=self.log_view)
        self.log_scroll.set_min_content_height(min(190, height // 3))
        self.log_scroll.set_visible(False)
        right.append(self.log_scroll)
        right.append(self.divider())

        self.actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        margin(self.actions, 9, 20, 10, 20)
        right.append(self.actions)
        self.window.present()
        self.start()

    @staticmethod
    def divider():
        widget = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
        widget.add_css_class("divider")
        return widget

    def toggle_terminal(self, button):
        show = button.get_active()
        self.terminal_arrow.set_text("⌄" if show else "›")
        self.log_scroll.set_visible(show)
        if show:
            self.log_view.scroll_to_mark(self.log_end, 0, False, 0, 0)

    def append_log(self, line):
        line = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", line)
        line = re.sub(r"https://auth\.altium\.com/connect/authorize\?[^\s\"]+",
                      "https://auth.altium.com/connect/authorize?[redacted]", line)
        line = re.sub(r"eyJ[\w-]+\.[\w-]+\.[\w-]+", "[session token redacted]", line)
        self.log.insert(self.log.get_end_iter(), line + "\n")
        if self.log.get_line_count() > 2500:
            _, end = self.log.get_iter_at_line(100)
            self.log.delete(self.log.get_start_iter(), end)
        if self.log_scroll.get_visible():
            self.log_view.scroll_to_mark(self.log_end, 0, False, 0, 0)
        if self.last_line is not None and line:
            self.last_line.set_text(line)

    def start(self):
        self.step = "installer"
        self.stage = "Starting"
        self.status = ""
        self.page = ("working",)
        self.pending = b""
        self.result = None
        self.log.set_text("")
        self.terminal.set_active(False)
        self.render()
        environment = dict(os.environ, ALTIUM_INSTALLER_UI="app")
        arguments = ["/bin/bash", str(self.script), "--root", str(self.root), *self.arguments]
        try:
            self.child = subprocess.Popen(arguments, env=environment, stdin=subprocess.PIPE,
                                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                          start_new_session=True)
        except OSError as error:
            self.append_log(str(error))
            self.fail(self.stage)
            return
        fd = self.child.stdout.fileno()
        os.set_blocking(fd, False)
        self.output_watch = GLib.io_add_watch(fd, GLib.PRIORITY_DEFAULT,
                                             GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR,
                                             self.read_output)
        GLib.timeout_add(120, self.poll_child, self.child)

    def drain_output(self, fd):
        while True:
            try:
                data = os.read(fd, 65536)
            except BlockingIOError:
                return True
            if not data:
                break
            lines = (self.pending + data).split(b"\n")
            self.pending = lines.pop()
            for line in lines:
                self.handle_line(line.decode("utf-8", errors="replace").rstrip("\r"))
        if self.pending:
            self.handle_line(self.pending.decode("utf-8", errors="replace"))
            self.pending = b""
        return False

    def read_output(self, fd, condition):
        if self.drain_output(fd) and not condition & (GLib.IO_HUP | GLib.IO_ERR):
            return GLib.SOURCE_CONTINUE
        self.output_watch = None
        return GLib.SOURCE_REMOVE

    def poll_child(self, child):
        if self.progress is not None:
            self.progress.pulse()
        code = child.poll()
        if code is None:
            return GLib.SOURCE_CONTINUE
        self.drain_output(child.stdout.fileno())
        if self.output_watch is not None:
            GLib.source_remove(self.output_watch)
            self.output_watch = None
        child.stdin.close()
        child.stdout.close()
        self.child = None
        if self.quitting:
            self.signal_child(child, signal.SIGKILL)
            self.quit()
        elif self.restart_root:
            self.root, self.restart_root = self.restart_root, None
            if "--no-launcher" not in self.arguments:
                self.arguments.append("--no-launcher")
            self.start()
        elif code == 0:
            self.page = ("finished", self.result or "Setup completed.")
            self.render()
        else:
            self.fail(self.result or self.stage)
        return GLib.SOURCE_REMOVE

    def handle_line(self, text):
        if not text.startswith("@@sw\t"):
            self.append_log(text)
            return
        event, *values = (decode_field(value) for value in text[5:].split("\t"))
        if event == "stage" and len(values) == 2:
            self.step, self.stage = values
            self.status = ""
            self.page = ("working",)
        elif event == "notify" and len(values) == 1:
            self.status = values[0]
            if self.status_label is not None:
                self.status_label.set_text(self.status or "Waiting…")
            return
        elif event == "welcome" and len(values) == 4:
            self.page = (event, *values)
        elif event == "choose" and len(values) == 2:
            self.page = (event, *values)
        elif event == "message" and len(values) == 3:
            self.page = (event, values[1], values[2], values[0])
        elif event == "wait" and len(values) == 3:
            self.page = ("waiting", values[0], values[1])
            self.status = values[2]
        elif event in ("failed", "finished") and len(values) == 1:
            self.result = values[0]
            return
        else:
            return
        self.render()

    def fail(self, stage):
        self.page = ("failed", stage)
        self.terminal.set_active(True)
        self.render()

    def reply(self, value):
        if self.child:
            try:
                self.child.stdin.write((value + "\n").encode())
                self.child.stdin.flush()
            except BrokenPipeError:
                return
            self.page = ("working",)
            self.status = ""
            self.render()

    def render_steps(self):
        clear(self.steps)
        title = label("Altium Designer", "brand")
        title.set_margin_bottom(10)
        self.steps.append(title)
        active = next((i for i, step in enumerate(STEPS) if step[0] == self.step), 0)
        for index, (_, text, subtitle) in enumerate(STEPS):
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            row.set_valign(Gtk.Align.START)
            indicator = Gtk.Box()
            indicator.set_size_request(18, 18)
            indicator.set_valign(Gtk.Align.START)
            indicator.set_halign(Gtk.Align.CENTER)
            if self.page[0] == "finished" or index < active:
                icon = Gtk.Label(label="✓")
                state = "done"
            elif index > active:
                icon = Gtk.Label()
                state = "pending"
            elif self.page[0] == "failed":
                icon = Gtk.Label(label="×")
                state = "error"
            elif self.page[0] in ("working", "waiting"):
                icon = Gtk.Spinner(spinning=True)
                state = None
            else:
                icon = Gtk.Label(label="→")
                state = "active"
            if state:
                icon.add_css_class("step-dot")
                icon.add_css_class(state)
            icon.set_size_request(13, 13)
            icon.set_halign(Gtk.Align.CENTER)
            icon.set_valign(Gtk.Align.CENTER)
            indicator.append(icon)
            row.append(indicator)
            copy = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            style = "current-step" if index == active else ("future-step" if index > active else None)
            copy.append(label(text, style))
            copy.append(label(subtitle, "subtitle", wrap=True))
            row.append(copy)
            self.steps.append(row)

    def button(self, text, callback, primary=False):
        widget = Gtk.Button(label=text)
        widget.add_css_class("action")
        if primary:
            widget.add_css_class("primary")
        widget.connect("clicked", lambda _button: callback())
        self.actions.append(widget)
        return widget

    def paragraph(self, text, style=None):
        self.content.append(label(text, style, wrap=True, selectable=True))

    def render(self):
        kind, *values = self.page
        clear(self.content)
        clear(self.actions)
        self.progress = self.status_label = self.last_line = None
        self.render_steps()
        self.button("Close" if kind == "finished" else "Quit", self.window.close)
        self.actions.append(Gtk.Box(hexpand=True))
        step_title = next((item[1].replace("\n", " ") for item in STEPS if item[0] == self.step),
                          "Prepare Wine")

        if kind == "welcome":
            installed, has_prefix, current, target = values
            self.content.append(label("Welcome", "heading"))
            if installed == "1" or has_prefix == "1":
                updating = installed == "1" and not any(
                    option in self.arguments for option in ("--altium-installer", "--reinstall-altium")
                )
                if updating:
                    self.paragraph(f"Altium Wine {current} is installed." if current else
                                   "An existing Altium Wine installation was found.")
                    title = f"Altium Wine {target}" if target not in ("", "dev") else "the latest kit"
                    self.paragraph(f"Update to {title} and keep Altium, your settings, and your projects.")
                else:
                    self.paragraph(f"Continue the Altium setup in {self.root}.")
                self.button("Clean Install…", self.choose_clean_root)
                if updating:
                    self.button("Update", lambda: self.reply("update"), primary=True)
                else:
                    self.button("Install Altium", lambda: self.reply("install"), primary=True)
            else:
                self.paragraph("This installs Altium Designer on Linux.")
                self.paragraph("Choose the installer from your Altium account, then follow the sign-in "
                               "instructions in Altium’s setup window.")
                self.paragraph("You need your own Altium license.")
                self.button("Clean Install", lambda: self.reply("install"), primary=True)
        elif kind == "choose":
            default, text = values
            self.content.append(label("Choose the Altium installer", "heading"))
            self.paragraph(text)
            self.file_entry(default)
        elif kind == "message":
            title, text, action = values
            self.content.append(label(title or step_title, "heading"))
            self.paragraph(text)
            self.button(action, lambda: self.reply("ok"), primary=True)
        elif kind == "waiting":
            title, text = values
            self.content.append(label(title or step_title, "heading"))
            self.paragraph(text)
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            row.append(Gtk.Spinner(spinning=True))
            self.status_label = label(self.status or "Waiting…", "muted", wrap=True)
            row.append(self.status_label)
            self.content.append(row)
        elif kind == "failed":
            self.content.append(label("⚠  Setup stopped", "heading danger"))
            self.paragraph(f"Setup stopped while {values[0]}. Details are in the terminal below.\n\n"
                           "Fix the problem, then click Try Again.")
            self.button("Try Again", self.start, primary=True)
        elif kind == "finished":
            self.content.append(label("✓  Setup is done", "heading success"))
            self.paragraph(values[0])
        else:
            self.content.append(label(step_title, "heading"))
            self.content.append(label(self.stage[:1].upper() + self.stage[1:] + "…", "stage"))
            self.progress = Gtk.ProgressBar()
            self.progress.pulse()
            self.content.append(self.progress)
            self.status_label = label(self.status, "muted", wrap=True)
            self.content.append(self.status_label)
            self.last_line = label("", "subtitle", ellipsize=Pango.EllipsizeMode.MIDDLE)
            self.content.append(self.last_line)

    def file_entry(self, default):
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        entry = Gtk.Entry(hexpand=True, placeholder_text="Online .exe, offline .zip, or extracted folder")
        row.append(entry)
        menu = Gtk.MenuButton(label="Browse…")
        popover = Gtk.Popover()
        choices = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        popover.set_child(choices)
        for title, action in (("Installer file…", Gtk.FileChooserAction.OPEN),
                              ("Extracted folder…", Gtk.FileChooserAction.SELECT_FOLDER)):
            choice = Gtk.Button(label=title)
            choice.connect("clicked", lambda _, a=action: self.browse(entry, popover, a))
            choices.append(choice)
        menu.set_popover(popover)
        row.append(menu)
        self.content.append(row)
        hint = label("", "muted", wrap=True)
        self.content.append(hint)

        def path():
            return Path(entry.get_text().strip()).expanduser()

        def validate(_entry):
            try:
                chosen = path()
                exists = bool(entry.get_text().strip()) and (chosen.is_dir() or
                         (chosen.is_file() and chosen.suffix.lower() in (".exe", ".zip")))
            except (OSError, RuntimeError):
                exists = False
            proceed.set_sensitive(exists)
            hint.set_text(f"✓  Found {chosen.name or chosen}" if exists else
                          "Choose the Altium installer you downloaded from your account.")
            if exists:
                hint.add_css_class("success")
            else:
                hint.remove_css_class("success")

        proceed = self.button("Continue", lambda: self.reply(str(path().resolve())), primary=True)
        entry.connect("changed", validate)
        entry.connect("activate", lambda _: proceed.emit("clicked") if proceed.get_sensitive() else None)
        entry.set_text(default)
        validate(entry)

    def browse(self, entry, popover, action):
        popover.popdown()
        if self.chooser is not None:
            return
        chooser = Gtk.FileChooserNative(title="Choose the Altium installer", transient_for=self.window,
                                        modal=True, action=action, accept_label="Choose", cancel_label="Cancel")
        if action == Gtk.FileChooserAction.OPEN:
            installer_types = Gtk.FileFilter(name="Altium installers")
            for suffix in ("exe", "zip"):
                if hasattr(installer_types, "add_suffix"):
                    installer_types.add_suffix(suffix)
                else:
                    installer_types.add_pattern("*." + suffix)
                    installer_types.add_pattern("*." + suffix.upper())
            chooser.add_filter(installer_types)
        downloads = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DOWNLOAD)
        if downloads and Path(downloads).is_dir():
            chooser.set_current_folder(Gio.File.new_for_path(downloads))

        def selected(dialog, response):
            if response == Gtk.ResponseType.ACCEPT:
                file = dialog.get_file()
                chosen = file.get_path() if file is not None else None
                if chosen is not None:
                    entry.set_text(chosen)
            dialog.destroy()
            self.chooser = None

        self.chooser = chooser
        chooser.connect("response", selected)
        chooser.show()

    def choose_clean_root(self):
        dialog = Gtk.Dialog(title="Clean Install", transient_for=self.window, modal=True)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        dialog.add_button("Continue", Gtk.ResponseType.ACCEPT)
        body = dialog.get_content_area()
        body.set_spacing(12)
        margin(body, 16, 18, 14, 18)
        body.append(label("Choose an empty location for a fresh installation.", wrap=True))
        body.append(label("Use a separate location to keep both installations.", wrap=True))
        entry = Gtk.Entry(text=str(self.root.with_name(self.root.name + "-clean")), width_chars=45)
        body.append(entry)
        feedback = label("", "danger", wrap=True)
        body.append(feedback)

        def selected(window, response):
            if response != Gtk.ResponseType.ACCEPT:
                window.destroy()
                return
            try:
                target = Path(entry.get_text().strip()).expanduser().resolve()
                valid = (bool(entry.get_text().strip()) and target != self.root and
                         self.root not in target.parents and
                         (not target.exists() or (target.is_dir() and not any(target.iterdir()))))
            except (OSError, RuntimeError):
                valid = False
            if not valid:
                feedback.set_text("Choose an empty location outside the existing installation.")
                return
            window.destroy()
            self.restart_root = target
            self.reply("@@quit")

        dialog.connect("response", selected)
        dialog.present()

    def request_close(self, _window):
        child = self.child
        if child is None or child.poll() is not None:
            return False
        if self.quitting:
            return True
        if self.step == "altium" and self.page[0] == "waiting":
            dialog = Gtk.MessageDialog(transient_for=self.window, modal=True,
                                       text="Altium setup is still running.",
                                       secondary_text="Close the Altium installer window to cancel setup.")
            dialog.add_button("OK", Gtk.ResponseType.CLOSE)
            dialog.connect("response", lambda widget, _: widget.destroy())
            dialog.present()
        elif self.page[0] in ("welcome", "choose", "message"):
            self.cancel(child)
        else:
            dialog = Gtk.MessageDialog(transient_for=self.window, modal=True,
                                       text="Quit Altium setup?", secondary_text="Setup is still running.")
            dialog.add_button("Keep Running", Gtk.ResponseType.CANCEL)
            dialog.add_button("Quit", Gtk.ResponseType.ACCEPT)
            dialog.connect("response", lambda widget, response: (widget.destroy(),
                           self.cancel(child) if response == Gtk.ResponseType.ACCEPT else None))
            dialog.present()
        return True

    def cancel(self, child):
        if child is not self.child:
            return
        self.quitting = True
        if self.page[0] in ("welcome", "choose", "message"):
            self.reply("@@quit")
        else:
            self.signal_child(child, signal.SIGTERM)
        GLib.timeout_add_seconds(2, self.finish_cancellation, child)

    def finish_cancellation(self, child):
        if child is self.child:
            self.signal_child(child, signal.SIGKILL)
        return GLib.SOURCE_REMOVE

    @staticmethod
    def signal_child(child, sig):
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--script", required=True, type=Path)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("options", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not Gtk.init_check():
        sys.exit("Linux graphical setup needs a display. Use install.sh --terminal for terminal setup.")
    options = args.options[1:] if args.options[:1] == ["--"] else args.options
    return Installer(args.script.resolve(), args.root.expanduser().resolve(), options).run([sys.argv[0]])


if __name__ == "__main__":
    sys.exit(main())

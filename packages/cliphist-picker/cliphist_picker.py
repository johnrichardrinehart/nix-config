#!/usr/bin/env python3

import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

import gi

gi.require_version("Gdk", "4.0")
gi.require_version("Gtk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")
from gi.repository import Gdk, Gio, GLib, GObject, Gtk, Gtk4LayerShell, Pango  # noqa: E402

CLIPHIST = "@cliphist@"
FILE = "@file@"
NIRI = "@niri@"
WL_COPY = "@wl_copy@"

MAX_WINDOW_WIDTH = 1200
MAX_WINDOW_HEIGHT = 760
DISPLAY_MARGIN = 96
PREVIEW_DEBOUNCE_MS = 100
IMAGE_METADATA_PATTERN = re.compile(
    r"\b(?:avif|bmp|gif|heic|heif|ico|jpe?g|png|svg|tiff?|webp)\b",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class HistoryEntry:
    raw: str
    label: str


class HistoryItem(GObject.Object):
    def __init__(self, entry: HistoryEntry | None) -> None:
        super().__init__()
        self.entry = entry


def parse_history(output: str) -> list[HistoryEntry]:
    entries = []
    for line in output.splitlines():
        if not line:
            continue
        _, separator, label = line.partition("\t")
        entries.append(HistoryEntry(raw=line, label=label if separator else line))
    return entries


def matches(entry: HistoryEntry, query: str) -> bool:
    return query.casefold() in entry.label.casefold()


def capped_window_size(width: int, height: int) -> tuple[int, int]:
    return (
        max(640, min(MAX_WINDOW_WIDTH, width - DISPLAY_MARGIN)),
        max(420, min(MAX_WINDOW_HEIGHT, height - DISPLAY_MARGIN)),
    )


def is_image_mime(mime_type: str) -> bool:
    return mime_type.startswith("image/")


def entry_kind(entry: HistoryEntry) -> str:
    if not entry.label.startswith("[[ binary data"):
        return "text"
    if IMAGE_METADATA_PATTERN.search(entry.label):
        return "image"
    return "binary"


class ClipboardPicker(Gtk.Application):
    def __init__(self) -> None:
        super().__init__(application_id="dev.johnrinehart.CliphistPicker")
        self.entries: list[HistoryEntry] = []
        self.items: list[HistoryItem] = []
        self.selected_entry: HistoryEntry | None = None
        self.preview_timeout: int | None = None
        self.tempdir: tempfile.TemporaryDirectory[str] | None = None
        self.window: Gtk.ApplicationWindow | None = None
        self.search: Gtk.SearchEntry | None = None
        self.result_store: Gio.ListStore | None = None
        self.selection: Gtk.SingleSelection | None = None
        self.list_view: Gtk.ListView | None = None
        self.history_scroll: Gtk.ScrolledWindow | None = None
        self.preview_picture: Gtk.Picture | None = None

    def do_activate(self) -> None:
        try:
            output = subprocess.run(
                [CLIPHIST, "list"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
        except subprocess.CalledProcessError as error:
            print(f"cliphist-picker: cannot read history: {error}", file=sys.stderr)
            self.quit()
            return

        self.entries = parse_history(output)
        if not self.entries:
            self.quit()
            return
        self.items = [HistoryItem(entry) for entry in self.entries]

        runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
        self.tempdir = tempfile.TemporaryDirectory(
            prefix="cliphist-picker-",
            dir=runtime_dir if runtime_dir and Path(runtime_dir).is_dir() else None,
        )

        self.window = Gtk.ApplicationWindow(application=self)
        self.window.set_title("Clipboard history")
        Gtk4LayerShell.init_for_window(self.window)
        Gtk4LayerShell.set_namespace(self.window, "johnos-cliphist-picker")
        Gtk4LayerShell.set_layer(self.window, Gtk4LayerShell.Layer.OVERLAY)
        Gtk4LayerShell.set_keyboard_mode(
            self.window, Gtk4LayerShell.KeyboardMode.EXCLUSIVE
        )

        monitor = self._focused_monitor()
        if monitor is not None:
            Gtk4LayerShell.set_monitor(self.window, monitor)
            geometry = monitor.get_geometry()
            window_width, window_height = capped_window_size(
                geometry.width, geometry.height
            )
        else:
            window_width, window_height = MAX_WINDOW_WIDTH, MAX_WINDOW_HEIGHT
        self.window.set_default_size(window_width, window_height)

        self._install_css()
        self.window.set_child(self._build_ui())

        controller = Gtk.EventControllerKey.new()
        controller.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        controller.connect("key-pressed", self._on_key_pressed)
        self.window.add_controller(controller)

        self.window.connect("close-request", self._on_close)
        self.window.present()
        self.search.grab_focus()
        self._set_results("")

    def _focused_monitor(self) -> Gdk.Monitor | None:
        connector = None
        try:
            focused_output = subprocess.run(
                [NIRI, "msg", "--json", "focused-output"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
            connector = json.loads(focused_output).get("name")
        except (subprocess.CalledProcessError, json.JSONDecodeError, AttributeError):
            pass

        display = Gdk.Display.get_default()
        if display is None:
            return None
        monitors = display.get_monitors()
        fallback = monitors.get_item(0) if monitors.get_n_items() else None
        for index in range(monitors.get_n_items()):
            monitor = monitors.get_item(index)
            if monitor is not None and monitor.get_connector() == connector:
                return monitor
        return fallback

    def _build_ui(self) -> Gtk.Widget:
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        root.add_css_class("picker-shell")

        self.search = Gtk.SearchEntry(placeholder_text="Search clipboard history")
        self.search.add_css_class("clipboard-search")
        self.search.connect("search-changed", self._on_search_changed)
        root.append(self.search)

        body = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        body.set_vexpand(True)
        root.append(body)

        history_frame = Gtk.Frame()
        history_frame.add_css_class("history-frame")
        history_frame.set_hexpand(True)
        history_frame.set_size_request(520, -1)
        body.append(history_frame)

        self.history_scroll = Gtk.ScrolledWindow()
        self.history_scroll.add_css_class("history-scroll")
        self.history_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.history_scroll.set_vexpand(True)
        history_frame.set_child(self.history_scroll)

        self.result_store = Gio.ListStore.new(HistoryItem)
        self.selection = Gtk.SingleSelection.new(self.result_store)
        self.selection.set_autoselect(False)
        self.selection.set_can_unselect(True)
        self.selection.connect("notify::selected", self._on_selection_changed)

        factory = Gtk.SignalListItemFactory.new()
        factory.connect("setup", self._on_factory_setup)
        factory.connect("bind", self._on_factory_bind)

        self.list_view = Gtk.ListView.new(self.selection, factory)
        self.list_view.add_css_class("history-list")
        self.list_view.set_vexpand(True)
        self.list_view.set_single_click_activate(False)
        self.list_view.connect("activate", self._on_list_activate)
        self.history_scroll.set_child(self.list_view)

        preview_frame = Gtk.Frame()
        preview_frame.add_css_class("preview-frame")
        preview_frame.set_hexpand(True)
        preview_frame.set_vexpand(True)
        preview_frame.set_size_request(500, -1)
        body.append(preview_frame)

        preview_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        preview_box.set_halign(Gtk.Align.FILL)
        preview_box.set_valign(Gtk.Align.FILL)
        preview_frame.set_child(preview_box)

        self.preview_picture = Gtk.Picture()
        self.preview_picture.set_content_fit(Gtk.ContentFit.CONTAIN)
        self.preview_picture.set_can_shrink(True)
        self.preview_picture.set_hexpand(True)
        self.preview_picture.set_vexpand(True)
        preview_box.append(self.preview_picture)

        return root

    def _on_factory_setup(
        self, _factory: Gtk.SignalListItemFactory, list_item: Gtk.ListItem
    ) -> None:
        content = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        content.add_css_class("row-content")

        number = Gtk.Label(xalign=1)
        number.add_css_class("result-number")
        number.set_width_chars(3)
        content.append(number)

        marker_stack = Gtk.Stack()
        image_marker = Gtk.Image.new_from_icon_name("image-x-generic-symbolic")
        image_marker.set_pixel_size(22)
        image_marker.add_css_class("type-marker")
        image_marker.add_css_class("type-marker-image")
        marker_stack.add_named(image_marker, "image")
        for kind, text in (("text", "AZ"), ("binary", "01")):
            marker = Gtk.Label(label=text)
            marker.add_css_class("type-marker")
            marker.add_css_class(f"type-marker-{kind}")
            marker_stack.add_named(marker, kind)
        content.append(marker_stack)

        label = Gtk.Label(xalign=0)
        label.set_hexpand(True)
        label.set_ellipsize(Pango.EllipsizeMode.END)
        label.set_single_line_mode(True)
        content.append(label)

        list_item.content = content
        list_item.number = number
        list_item.marker_stack = marker_stack
        list_item.label = label
        list_item.set_child(content)

    def _on_factory_bind(
        self, _factory: Gtk.SignalListItemFactory, list_item: Gtk.ListItem
    ) -> None:
        item = list_item.get_item()
        entry = item.entry
        is_empty = entry is None
        list_item.content.remove_css_class("empty-results-content")
        list_item.number.set_visible(not is_empty)
        list_item.marker_stack.set_visible(not is_empty)
        list_item.label.set_xalign(0.5 if is_empty else 0)

        if is_empty:
            list_item.content.add_css_class("empty-results-content")
            list_item.content.set_size_request(
                -1, max(72, self.history_scroll.get_height())
            )
            list_item.label.set_label("No clipboard matches")
            list_item.label.set_tooltip_text(None)
            return

        list_item.content.set_size_request(-1, -1)
        list_item.number.set_label(str(list_item.get_position() + 1))
        list_item.marker_stack.set_visible_child_name(entry_kind(entry))
        list_item.label.set_label(entry.label)
        list_item.label.set_tooltip_text(entry.label)

    def _install_css(self) -> None:
        css = b"""
            window {
                background: transparent;
            }
            .picker-shell {
                background: rgba(32, 36, 45, 0.97);
                border: 2px solid #5e81ac;
                border-radius: 12px;
                padding: 18px;
            }
            .clipboard-search {
                min-height: 42px;
                color: #edf1f7;
                background: #272d38;
                border: 1px solid #60758f;
                border-radius: 9px;
                caret-color: #d8dee9;
                font: 16px "Fira Code";
                box-shadow: none;
            }
            .clipboard-search:focus-within {
                border-color: #88a9c5;
                box-shadow: 0 0 0 1px rgba(136, 169, 197, 0.35);
            }
            .clipboard-search text {
                color: #edf1f7;
                background: transparent;
                caret-color: #d8dee9;
            }
            .clipboard-search text selection {
                color: #f7f9fc;
                background: #526b87;
            }
            .clipboard-search image {
                color: #b8c4d4;
            }
            .history-frame, .preview-frame {
                border: 1px solid #465669;
                border-radius: 9px;
                background: #191e27;
                padding: 8px;
            }
            .history-scroll,
            .history-scroll undershoot,
            .history-list {
                color: #dce2eb;
                background: #191e27;
            }
            .history-list row {
                color: #dce2eb;
                background-color: #191e27;
                background-image: none;
                border: none;
                outline: none;
                box-shadow: none;
                padding: 0;
            }
            .history-list row > .row-content {
                color: #dce2eb;
                background-color: #191e27;
                border: 1px solid #191e27;
                border-radius: 7px;
                padding: 9px 11px 9px 4px;
            }
            .history-list row:hover > .row-content {
                color: #edf1f7;
                background-color: #252d39;
                border-color: #354354;
            }
            .history-list row:selected > .row-content,
            .history-list row:selected:hover > .row-content,
            .history-list row:selected:focus > .row-content {
                color: #f4f7fb;
                background-color: #303c4a;
                border-color: #b7c8d9;
                box-shadow: 0 0 0 1px rgba(183, 200, 217, 0.12);
            }
            .history-list row:selected label,
            .history-list row:selected image {
                color: #f4f7fb;
            }
            .history-list row > .empty-results-content,
            .history-list row:hover > .empty-results-content {
                color: #aeb8c8;
                background-color: #191e27;
                border-color: #191e27;
                font-size: 15px;
                font-weight: bold;
            }
            .result-number {
                min-width: 24px;
                color: #77869a;
                font-family: monospace;
                font-size: 11px;
                font-weight: bold;
            }
            .type-marker {
                min-width: 28px;
                min-height: 24px;
                color: #88c0d0;
                font-family: monospace;
                font-size: 11px;
                font-weight: bold;
            }
            .type-marker-image {
                color: #a3be8c;
            }
            .type-marker-binary {
                color: #b48ead;
            }
        """
        provider = Gtk.CssProvider()
        provider.load_from_data(css)
        display = Gdk.Display.get_default()
        if display is not None:
            Gtk.StyleContext.add_provider_for_display(
                display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            )

    def _on_search_changed(self, search: Gtk.SearchEntry) -> None:
        self._set_results(search.get_text())

    def _set_results(self, query: str) -> None:
        results = [item for item in self.items if matches(item.entry, query)]
        additions = results if results else [HistoryItem(None)]
        self.selection.set_selected(Gtk.INVALID_LIST_POSITION)
        self.result_store.splice(0, self.result_store.get_n_items(), additions)
        self.selection.set_selected(0 if results else Gtk.INVALID_LIST_POSITION)
        GLib.idle_add(self._scroll_to_top)

    def _scroll_to_top(self) -> bool:
        adjustment = self.history_scroll.get_vadjustment()
        adjustment.set_value(adjustment.get_lower())
        return GLib.SOURCE_REMOVE

    def _center_selected_position(self, position: int) -> bool:
        if position != self.selection.get_selected():
            return GLib.SOURCE_REMOVE
        item_count = self.result_store.get_n_items()
        if not item_count:
            return GLib.SOURCE_REMOVE

        adjustment = self.history_scroll.get_vadjustment()
        row_center = adjustment.get_upper() * (position + 0.5) / item_count
        target = row_center - adjustment.get_page_size() / 2
        maximum = max(
            adjustment.get_lower(), adjustment.get_upper() - adjustment.get_page_size()
        )
        adjustment.set_value(max(adjustment.get_lower(), min(target, maximum)))
        return GLib.SOURCE_REMOVE

    def _move_selection(self, delta: int) -> None:
        item_count = self.result_store.get_n_items()
        if not item_count or self.result_store.get_item(0).entry is None:
            return
        selected = self.selection.get_selected()
        if selected == Gtk.INVALID_LIST_POSITION:
            selected = 0
        position = max(0, min(item_count - 1, selected + delta))
        self.selection.set_selected(position)
        self.list_view.scroll_to(
            position, Gtk.ListScrollFlags.FOCUS | Gtk.ListScrollFlags.SELECT, None
        )
        GLib.idle_add(self._center_selected_position, position)
        self.search.grab_focus()

    def _on_key_pressed(
        self,
        _controller: Gtk.EventControllerKey,
        keyval: int,
        _keycode: int,
        _state: Gdk.ModifierType,
    ) -> bool:
        if keyval == Gdk.KEY_Escape:
            self.quit()
            return True
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            self._copy_selected()
            return True
        if keyval in (Gdk.KEY_Down, Gdk.KEY_KP_Down):
            self._move_selection(1)
            return True
        if keyval in (Gdk.KEY_Up, Gdk.KEY_KP_Up):
            self._move_selection(-1)
            return True
        if keyval in (Gdk.KEY_Page_Down, Gdk.KEY_KP_Page_Down):
            self._move_selection(10)
            return True
        if keyval in (Gdk.KEY_Page_Up, Gdk.KEY_KP_Page_Up):
            self._move_selection(-10)
            return True
        return False

    def _on_selection_changed(
        self, _selection: Gtk.SingleSelection, _parameter: GObject.ParamSpec
    ) -> None:
        position = self.selection.get_selected()
        item = (
            self.result_store.get_item(position)
            if position != Gtk.INVALID_LIST_POSITION
            else None
        )
        self.selected_entry = item.entry if item is not None else None
        if self.preview_timeout is not None:
            GLib.source_remove(self.preview_timeout)
            self.preview_timeout = None
        if self.selected_entry is None:
            self._clear_preview()
            return
        self.preview_timeout = GLib.timeout_add(
            PREVIEW_DEBOUNCE_MS, self._update_preview, self.selected_entry
        )

    def _on_list_activate(self, _list_view: Gtk.ListView, position: int) -> None:
        item = self.result_store.get_item(position)
        if item is None or item.entry is None:
            return
        self.selection.set_selected(position)
        self._copy_selected()

    def _decode(self, entry: HistoryEntry) -> bytes:
        return subprocess.run(
            [CLIPHIST, "decode"],
            input=f"{entry.raw}\n".encode(),
            check=True,
            capture_output=True,
        ).stdout

    def _update_preview(self, entry: HistoryEntry) -> bool:
        self.preview_timeout = None
        if entry != self.selected_entry:
            return GLib.SOURCE_REMOVE
        try:
            payload = self._decode(entry)
            payload_path = Path(self.tempdir.name) / "preview"
            payload_path.write_bytes(payload)
            mime_type = subprocess.run(
                [FILE, "--mime-type", "--brief", payload_path],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
        except (OSError, subprocess.CalledProcessError) as error:
            print(f"cliphist-picker: preview failed: {error}", file=sys.stderr)
            self._clear_preview()
            return GLib.SOURCE_REMOVE

        if not is_image_mime(mime_type):
            self._clear_preview()
            return GLib.SOURCE_REMOVE

        try:
            texture = Gdk.Texture.new_from_filename(str(payload_path))
        except GLib.Error as error:
            print(f"cliphist-picker: image render failed: {error}", file=sys.stderr)
            self._clear_preview()
            return GLib.SOURCE_REMOVE

        self.preview_picture.set_paintable(texture)
        return GLib.SOURCE_REMOVE

    def _clear_preview(self) -> None:
        self.preview_picture.set_paintable(None)

    def _copy_selected(self) -> None:
        if self.selected_entry is None:
            return
        try:
            payload = self._decode(self.selected_entry)
            subprocess.run([WL_COPY], input=payload, check=True)
        except subprocess.CalledProcessError as error:
            print(f"cliphist-picker: clipboard copy failed: {error}", file=sys.stderr)
            self._clear_preview()
            return
        self.quit()

    def _on_close(self, _window: Gtk.ApplicationWindow) -> bool:
        self.quit()
        return False

    def do_shutdown(self) -> None:
        if self.preview_timeout is not None:
            GLib.source_remove(self.preview_timeout)
            self.preview_timeout = None
        if self.tempdir is not None:
            self.tempdir.cleanup()
            self.tempdir = None
        Gtk.Application.do_shutdown(self)


def main() -> int:
    return ClipboardPicker().run(sys.argv)


if __name__ == "__main__":
    raise SystemExit(main())

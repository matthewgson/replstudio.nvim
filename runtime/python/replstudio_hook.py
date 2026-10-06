"""replstudio.nvim plot capture for matplotlib and plotnine.

Runs after every REPL command. Costs a couple of dict lookups unless
matplotlib or plotnine have actually been imported; neither is imported
here. Figures are written atomically as <page>_<rev>.png into
$REPLSTUDIO_DIR: a new figure is a new page, a changed figure a new rev.
"""

import os
import sys

DIR = os.environ.get("REPLSTUDIO_DIR", "")

_figs = {}  # figure number -> [page, rev, figure, size rendered at]
_page = 0
_size = None  # (w_px, h_px, dpi)
_size_mtime = None


def _read_size():
    """(width_px, height_px, dpi) from Neovim, re-read only when it changes."""
    global _size, _size_mtime
    path = os.path.join(DIR, "size")
    try:
        mtime = os.stat(path).st_mtime_ns
    except OSError:
        return _size
    if mtime != _size_mtime:
        _size_mtime = mtime
        try:
            w, h, dpi = (int(v) for v in open(path).read().split())
            _size = (w, h, dpi)
        except (OSError, ValueError):
            pass
    return _size


def apply_size():
    """Default size of *new* figures follows the plot pane."""
    size = _read_size()
    if not size:
        return
    w, h, dpi = size
    inches = (w / dpi, h / dpi)
    mpl = sys.modules.get("matplotlib")
    if mpl is not None:
        mpl.rcParams["figure.figsize"] = inches
        mpl.rcParams["savefig.dpi"] = dpi
    pn = sys.modules.get("plotnine")
    if pn is not None:
        try:
            pn.options.figure_size = inches
            pn.options.dpi = dpi
        except Exception:
            pass


def _write(fig, page, rev):
    """Render at the pane's size; the figure's own size is restored after."""
    name = "%04d_%03d" % (page, rev)
    tmp = os.path.join(DIR, ".%s.tmp" % name)
    size = _read_size()
    old = fig.get_size_inches().copy()
    try:
        if size:
            w, h, dpi = size
            fig.set_size_inches(w / dpi, h / dpi, forward=False)
            fig.savefig(tmp, format="png", dpi=dpi)
        else:
            fig.savefig(tmp, format="png")
        os.replace(tmp, os.path.join(DIR, name + ".png"))
    except Exception as e:  # never break the user's session
        try:
            os.unlink(tmp)
        except OSError:
            pass
        sys.stderr.write("replstudio: could not save figure: %s\n" % e)
    finally:
        fig.set_size_inches(old, forward=False)


def save_figure(fig, num=None):
    """Save one figure as a new page, or a new rev when we've seen it."""
    global _page
    key = num if num is not None else id(fig)
    entry = _figs.get(key)
    if entry is None or entry[2] is not fig:
        _page += 1
        entry = [_page, 0, fig, None]
        _figs[key] = entry
    else:
        entry[1] += 1
    _write(fig, entry[0], entry[1])
    entry[3] = _size
    # savefig() restores the figure's dpi afterwards, which marks it stale
    # again; it is clean as far as the pane is concerned.
    fig.stale = False
    fig.canvas._replstudio_dirty = False


def _dirty(fig):
    return fig.stale or getattr(fig.canvas, "_replstudio_dirty", False)


def flush(close=False):
    """Save every new or changed pyplot figure; `close` mimics inline show()."""
    plt = sys.modules.get("matplotlib.pyplot")
    if plt is None:
        return
    from matplotlib._pylab_helpers import Gcf

    live = set()
    for manager in Gcf.get_all_fig_managers():
        num, fig = manager.num, manager.canvas.figure
        live.add(num)
        entry = _figs.get(num)
        if entry is None or entry[2] is not fig or _dirty(fig) or entry[3] != _read_size():
            if fig.axes or fig.texts or fig.images:
                save_figure(fig, num)
    for num in list(_figs):
        if isinstance(num, int) and num not in live:
            del _figs[num]
    if close:
        plt.close("all")
        _figs.clear()


def is_ggplot(value):
    """plotnine ggplot, recognised without importing plotnine."""
    return type(value).__module__.startswith("plotnine") and hasattr(value, "draw")


def show_ggplot(p):
    import matplotlib.pyplot as plt

    fig = p.draw()
    save_figure(fig)
    plt.close(fig)


def displayhook(prev):
    """Plain REPL: evaluating a ggplot draws it into the pane."""

    def hook(value):
        if value is not None and is_ggplot(value):
            import builtins

            show_ggplot(value)
            builtins._ = value
            return
        prev(value)

    return hook


def after_command(*_args, **_kwargs):
    if not DIR:
        return
    try:
        flush()
        apply_size()
    except Exception as e:
        sys.stderr.write("replstudio: %s\n" % e)

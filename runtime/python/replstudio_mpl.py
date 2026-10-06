"""matplotlib backend for replstudio.nvim (MPLBACKEND=module://replstudio_mpl).

Agg rendering; nothing is drawn until a figure is saved for the plot pane.
"""

from matplotlib.backend_bases import FigureManagerBase, _Backend
from matplotlib.backends.backend_agg import FigureCanvasAgg

import replstudio_hook as _hook

# Figures created in the very command that imports pyplot already fit the pane.
_hook.apply_size()


class FigureManager(FigureManagerBase):
    def show(self):  # fig.show()
        _hook.save_figure(self.canvas.figure, self.num)


class FigureCanvas(FigureCanvasAgg):
    manager_class = FigureManager

    def draw_idle(self, *args, **kwargs):
        # Interactive mode asks for a redraw after every pyplot call. Defer:
        # the post-command hook renders once per command instead.
        self._replstudio_dirty = True


@_Backend.export
class _BackendReplStudio(_Backend):
    FigureCanvas = FigureCanvas
    FigureManager = FigureManager

    @staticmethod
    def show(*args, **kwargs):
        _hook.flush(close=True)

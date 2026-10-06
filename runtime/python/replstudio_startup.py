# replstudio.nvim startup (PYTHONSTARTUP). Keep this import-light: no
# matplotlib, no plotnine — only a hook that runs after each command.


def _replstudio_init():
    import os
    import sys

    orig = os.environ.get("REPLSTUDIO_PYTHONSTARTUP")
    if orig and os.path.isfile(orig):
        with open(orig) as f:
            exec(compile(f.read(), orig, "exec"), sys.modules["__main__"].__dict__)

    # Code from a .qmd runs in the document's folder, like `quarto render`
    # (the REPL started in the project root so its venv was found).
    wd = os.environ.get("REPLSTUDIO_WD")
    if wd and os.path.isdir(wd):
        os.chdir(wd)

    import replstudio_hook

    try:
        ip = get_ipython()  # noqa: F821 (IPython builtin)
    except NameError:
        ip = None
    if ip is not None:
        ip.events.register("post_run_cell", replstudio_hook.after_command)
        # Registered by name: plotnine needn't be imported yet. Takes
        # precedence over plotnine's own _repr_mimebundle_.
        ip.display_formatter.ipython_display_formatter.for_type_by_name(
            "plotnine.ggplot", "ggplot", replstudio_hook.show_ggplot
        )
        return

    # Plain REPL: str(sys.ps1) is evaluated before every prompt.
    class _Prompt:
        def __init__(self, inner):
            self.inner = inner

        def __str__(self):
            replstudio_hook.after_command()
            return str(self.inner)

    sys.ps1 = _Prompt(getattr(sys, "ps1", ">>> "))
    sys.displayhook = replstudio_hook.displayhook(sys.displayhook)


_replstudio_init()
del _replstudio_init

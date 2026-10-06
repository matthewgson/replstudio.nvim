# replstudio.nvim R hook, loaded through R_PROFILE_USER.
#
# Plots draw onto an off-screen null device; after each top-level command a
# task callback re-renders the current page to PNG (ragg, or quartz/cairo) at the plot pane's
# pixel size, written atomically into $REPLSTUDIO_DIR for Neovim to show.
# Nothing here loads ggplot2 or other packages up front.

# R reads R_PROFILE_USER *instead of* ./.Rprofile and ~/.Rprofile, so chain
# to whichever one R would have used (this keeps renv projects working).
local({
  prof <- Sys.getenv("REPLSTUDIO_R_PROFILE_USER")
  if (!nzchar(prof)) {
    prof <- if (file.exists(".Rprofile")) ".Rprofile" else path.expand("~/.Rprofile")
  }
  if (file.exists(prof)) source(prof, local = FALSE)
})

# Code from a .qmd runs in the document's folder, like `quarto render`. The
# profile above already ran from the project root (renv & co).
local({
  wd <- Sys.getenv("REPLSTUDIO_WD")
  if (nzchar(wd) && dir.exists(wd)) setwd(wd)
})

local({
  dir <- Sys.getenv("REPLSTUDIO_DIR")
  if (!nzchar(dir) || !interactive()) return(invisible())

  st <- new.env(parent = emptyenv())
  st$devs <- integer()   # devices we opened (user's own png()/pdf() are left alone)
  st$page <- 0L          # bumped on every new page
  st$saved_page <- -1L   # page / display-list length of the last PNG
  st$saved_len <- -1L
  st$rev <- 0L
  st$busy <- FALSE       # TRUE while we replay onto the PNG device
  st$png <- NULL        # PNG device that works here, picked on first use
  forced <- Sys.getenv("REPLSTUDIO_R_DEVICE") # ragg | quartz | cairo | default
  if (forced %in% c("ragg", "quartz", "cairo", "default")) st$png <- forced

  # ragg if installed (best text rendering); otherwise the native quartz
  # device on macOS (CRAN R's cairo needs XQuartz), then cairo, then R's
  # default. The first one that actually opens is remembered.
  open_png <- function(file, v) {
    devices <- list(
      ragg = function() ragg::agg_png(file, width = v[1], height = v[2], res = v[3], background = "white"),
      quartz = function() grDevices::png(file, width = v[1], height = v[2], res = v[3], type = "quartz", bg = "white"),
      cairo = function() grDevices::png(file, width = v[1], height = v[2], res = v[3], type = "cairo", bg = "white"),
      default = function() grDevices::png(file, width = v[1], height = v[2], res = v[3], bg = "white")
    )
    if (!is.null(st$png)) {
      before <- grDevices::dev.cur()
      ok <- tryCatch(suppressWarnings({ devices[[st$png]](); TRUE }), error = function(e) FALSE)
      if (ok && grDevices::dev.cur() != before) return(invisible(TRUE))
      st$png <- NULL # forced/remembered device stopped working: detect again
    }
    if (!requireNamespace("ragg", quietly = TRUE)) devices$ragg <- NULL
    if (!isTRUE(capabilities("aqua"))) devices$quartz <- NULL
    for (name in names(devices)) {
      before <- grDevices::dev.cur()
      ok <- tryCatch(suppressWarnings({ devices[[name]](); TRUE }), error = function(e) FALSE)
      if (ok && grDevices::dev.cur() != before) {
        st$png <- name
        return(invisible(TRUE))
      }
    }
    stop("replstudio: no working PNG device")
  }

  size <- function() {
    v <- tryCatch(scan(file.path(dir, "size"), quiet = TRUE), error = function(e) NULL)
    if (length(v) == 3 && all(v > 0)) v else c(1000, 750, 144)
  }

  ours <- function() {
    cur <- grDevices::dev.cur()
    cur > 1L && cur %in% st$devs
  }

  # Re-renders when the page changed, or when the pane was resized since
  # (so a layout switch refits the current plot on the next command).
  render <- function() {
    p <- grDevices::recordPlot()
    len <- length(p[[1]])
    if (len == 0L) return(invisible())
    v <- size()
    if (st$page == st$saved_page && len == st$saved_len && identical(v, st$saved_size)) return(invisible())
    st$rev <- if (st$page == st$saved_page) st$rev + 1L else 0L
    st$saved_page <- st$page
    st$saved_len <- len
    st$saved_size <- v
    name <- sprintf("%04d_%03d", st$page, st$rev)
    tmp <- file.path(dir, paste0(".", name, ".tmp"))
    cur <- grDevices::dev.cur()
    st$busy <- TRUE
    on.exit({
      st$busy <- FALSE
      if (cur %in% grDevices::dev.list()) grDevices::dev.set(cur)
    })
    open_png(tmp, v)
    ok <- tryCatch({ grDevices::replayPlot(p); TRUE }, error = function(e) FALSE)
    grDevices::dev.off()
    if (ok) file.rename(tmp, file.path(dir, paste0(name, ".png"))) else unlink(tmp)
    invisible()
  }

  # A page about to be replaced (loops, several plots in one chunk) is saved
  # first, so every page a command draws lands in the history. Base graphics
  # only start a new page when par("page") says so (a par(mfrow) grid fills
  # one page).
  before_base <- function(...) {
    st$base_new <- FALSE
    if (st$busy) return(invisible())
    if (grDevices::dev.cur() == 1L) {
      st$base_new <- TRUE # first plot opens a fresh device
    } else if (ours() && isTRUE(graphics::par("page"))) {
      st$base_new <- TRUE
      try(render(), silent = TRUE)
    }
  }
  after_base <- function(...) {
    if (!st$busy && ours() && isTRUE(st$base_new)) st$page <- st$page + 1L
  }
  before_grid <- function(...) {
    if (!st$busy && ours()) try(render(), silent = TRUE)
  }
  after_grid <- function(...) {
    if (!st$busy && ours()) st$page <- st$page + 1L
  }
  setHook("before.plot.new", before_base)
  setHook("plot.new", after_base)
  setHook("before.grid.newpage", before_grid)
  setHook("grid.newpage", after_grid)

  options(device = function(...) {
    grDevices::pdf(NULL, width = 7, height = 7 * 0.75)
    grDevices::dev.control("enable")
    st$devs <- c(st$devs, grDevices::dev.cur())
  })

  # htmlwidgets & friends: the browser (a terminal can't show HTML).
  options(viewer = function(url, ...) utils::browseURL(url))

  invisible(addTaskCallback(function(...) {
    if (ours()) try(render(), silent = TRUE)
    TRUE
  }, name = "replstudio"))
})

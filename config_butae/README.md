# buatae.sh – ANSI Art Editor: A Programmer’s Primer

## Overview

`buatae` is a full‑screen terminal art editor written entirely in Bash. It uses ANSI escape sequences for colors, mouse tracking, and cursor movement. It stores the drawing as a grid of glyphs and per‑cell foreground/background colors in associative arrays. The program supports loading/saving ANSI text files, a palette picker, a brush selector, and panning via arrow keys.

This document explains the program’s architecture, the role of each function, and pitfalls encountered during development. It is intended to help future maintainers understand and extend the code safely.

---

## Architecture

### Core Data Structures

- `IMG_GLYPHS[col,row]` – the character at each cell.
- `IMG_COLORS[col,row]` – the ANSI SGR string (foreground and background) for that cell.
- `CHR_ARRAY[col,row]` – brush characters loaded from a data file.
- `PAL_ARRAY` – flat list of RGB triplets (e.g., `"175;175;175"`).
- `BBOX_*` – arrays holding bounding boxes for palette, menu, brushes, drawing window.

### Terminal Setup

- Saves original `stty` settings, disables echo/line‑buffering, enables mouse tracking (`ESC[?1002h`), hides cursor.
- On exit, restores terminal state and shows cursor.

### Main Loop

- Uses a byte‑by‑byte state machine to parse input:
  - Printable keys → `KEYCMD` (handled by `handle_keys`).
  - CSI sequences (arrow keys) → `USERHIT` values like `KeyUp`, `KeyDown`, etc.
  - X10 mouse events → `USERHIT=Mouse`, sets `MOUSEBT`, `X`, `Y`.
- On each event, dispatches to the appropriate handler.
- Handles `SIGWINCH` for terminal resize via a flag.

---

## Function Synopses

### Terminal & Utility Functions

| Function | Purpose | Caveats |
|----------|---------|---------|
| `set_pos col row` | Moves cursor using ANSI `\e[row;colf`. | Column and row are 1‑based. |
| `mybeep` | Plays a beep if the `beep` program exists in `$bd_datadir`. | Silently fails if missing. |
| `read_char var` | Reads a single character into a variable via `dd`. | Blocking; used in old code. |
| `truncate_path_display` | Shortens a filename for display. | Handles directories. |
| `truncate_name` | Similar, but for file selector entries. | |

### Rendering Functions

| Function | Purpose | Caveats |
|----------|---------|---------|
| `draw_bg_border` | Clears screen, draws a border and random background pattern. | Uses `tput cols/lines`; must be called after resize. |
| `draw_menu` | Draws the top menu bar. | Uses hard‑coded positions derived from `BBOX_MENUITM`. |
| `draw_chr` | Draws the brush selector box (grid of characters). | Relies on `CHR_MAX_COLS` and `CHR_ARRAY_Y`; may break if data file changes. |
| `draw_pal` | Draws the palette grid. | Iterates `PAL_ARRAY`; expects exactly 520 entries. |
| `draw_drawwin` | Fills the drawing area with a dotted background. | Slow; used only for initial clear or after resize. |
| `draw_image` | Renders the visible portion of the image into the drawing window. | **Must clear the status line first** (see Pitfalls). Uses `DRAWWIN_OFFX/Y` for panning. |
| `show_fgbg` | Shows current foreground/background color swatches below the palette. | |

### Image I/O

| Function | Purpose | Caveats |
|----------|---------|---------|
| `load_image` | Parses an ANSI file and populates `IMG_GLYPHS`/`IMG_COLORS`. | Two versions exist; `load_image2` is a state‑machine parser. The original `load_image` uses field splitting on `ESC` and may mishandle consecutive SGR sequences. Use `load_image2` if possible. |
| `save_image` | Writes the entire image to a file. | Validates filename with `^[a-zA-Z0-9._/-]+$`. Asks for overwrite confirmation. |
| `img_numcols` | Counts unique colors (unused). | |

### Input Handling

| Function | Purpose | Caveats |
|----------|---------|---------|
| `process_byte` | Feeds one byte into the state machine. | States: 0=idle, 1=ESC, 2=ESC[, 3=X10 mouse, 4=SGR mouse, 5=CSI params. |
| `parse_x10_mouse` | Decodes 6‑byte X10 mouse sequence. | |
| `parse_sgr_mouse` | Decodes SGR mouse sequence. | |
| `handle_csi_sequence` | Maps CSI sequences to arrow keys. | |
| `click_item` | Determines which UI region was clicked and acts accordingly. | Coordinate checks must use `(( ... ))` arithmetic, not `[[ ... ]]` with `-ge` on strings. |
| `handle_keys` | Handles single‑key shortcuts (H, L, S, G, P, I, T, U, R, Q, x). | |

### File Selector

| Function | Purpose | Caveats |
|----------|---------|---------|
| `list_files` | Populates `FILE_LIST` with directories and `.ans` files. | Uses `find` with `-print0`; sorts alphabetically. |
| `draw_file_selector` | Draws the overlay with file names in a grid. | |
| `file_selector` | Main loop for browsing/selecting a file. | Uses `read -r -n1 -t 0.1`; handles arrow keys and Enter. |

### Save Dialog

| Function | Purpose | Caveats |
|----------|---------|---------|
| `save_status_dialog` | Edits a filename on the status line; saves on Enter, aborts on Esc. | Must clear status line first; flushes input buffer. Uses `read` with a timeout. |

### Resize Handling

| Function | Purpose | Caveats |
|----------|---------|---------|
| `handle_resize` | Re‑reads terminal size, recalculates bounding boxes, redraws all. | Called when `RESIZE_NEEDED` flag is set. |

### Exit & Cleanup

| Function | Purpose | Caveats |
|----------|---------|---------|
| `at_exit` | Restores terminal, optionally prompts to save, exits. | Trapped on `EXIT` and `ERR`. |

---

## Pitfalls & Lessons Learned

1. **Arithmetic Expansion**  
   - Use `$(( ... ))` for arithmetic
   - In array assignments, write `BBOX_DRAWWIN=( $(( ... - 2 )) 3 ... )` – do not omit the inner `$((` and `))`.  
   - Example error: `BBOX_DRAWWIN=($(${BBOX_PALETTE[3]}-2) ...)` caused `28-2: command not found`.

2. **Conditional Expressions**  
   - Use `[[ "$char" =~ [[:print:]] ]]` to test printable characters.  
   - Avoid `[[ "$char" >= ' ' && "$char" <= '~' ]]` – this is invalid inside `[[ ]]`.  
   - For numeric comparisons, use `(( ... ))` instead of `[[ ... ]]` with `-ge`, especially when variables are array elements.

3. **Mouse Input Handling**  
   - After a mouse click, leftover bytes may remain in the input buffer. Always flush with `IFS= read -r -t 0 -n 1000 dummy 2>/dev/null || true` before starting a new input mode (e.g., the save dialog).  
   - Ensure coordinate checks use proper arithmetic: `if (( X >= BBOX_MENUITM[0] + 5 && X <= BBOX_MENUITM[0] + 11 ))`.

4. **Terminal State**  
   - `stty` changes only affect the terminal driver, not the screen buffer or cursor position.  
   - When using `read -e` for line editing, you must temporarily restore cooked mode, then re‑enter raw mode, and flush the input after.

5. **Status Line Overdraw**  
   - `draw_image` must clear the entire status line (e.g., `printf "%*s" $width ""`) before writing new text; otherwise residual characters appear.

6. **ANSI Parsing**  
   - The original `load_image` used `IFS=$'\e' read -a fields`; this breaks when an SGR sequence is followed directly by text without a reset. `load_image2` is more robust. Prefer `load_image2` for new code.

7. **Resize Handling**  
   - Always re‑read `tput cols/lines` after `SIGWINCH`. Recalculate bounding boxes and redraw all UI elements. Use a flag (`RESIZE_NEEDED`) to avoid blocking in the signal handler.

8. **File Saving**  
   - Filename validation regex is strict (`^[a-zA-Z0-9._/-]+$`). If users need spaces, adjust the regex accordingly. Trim leading/trailing whitespace before saving.

---

## Running buatae

- **Dependencies:** Bash 4+ (associative arrays), `stty`, `tput`, `dd`, `find`, `sed` (optional).  
- **Minimum terminal size:** 120 columns × 40 rows.  
- **Data files:**  
  - `$HOME/.config/buatae/pal-artiste_520-20x26.txt` – palette colors.  
  - `$HOME/.config/buatae/chr-deluxe-103x4.bchr` – brush characters.  
- **Usage:** `./buatae.sh [filename.ans]`  
  - If no filename given, defaults to `default.ans`.  
  - `-h` or `--help` prints usage.


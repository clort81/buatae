# buatae.sh – Bash UTF‑8 ANSI Text Art Editor

![buatae.gif](buatae.gif)

## Abstract

**buatae** is an ANSI textart editor written entirely in **Bash**.  Development began in 2015 as a way to edit output from the "Chafa" image-to-textart convertor https://github.com/hpjansson/chafa.  Inspired by bruxy ( https://bruxy.regnet.cz/web/ ).

It's UTF-8 and 24-bit color native. Offers mouse tracking for easy selection and drawing.  Works great on a truly compatible terminal emulator (xterm) and somewhat-well on the *lesser* terminal-emulator-approximators (libvte terminals, suckless, gnome‑terminal, kitty, urxvt, etc.).

We wuz into TUI apps before GUI was widely available and are pleeezed that it has become trendy again. 

Create ANSI art anywhere you have a compatible terminal, e.g. a headless server even on a text-only bulletin board system.

---

## Usage Synopsis

```bash
./buatae.sh [filename.ans]
```

If no filename is given, it opens `default.ans`. Use `-h` or `--help` for a brief usage message.

### Requirements

- Bash 4.0 or later (for associative arrays)
- A terminal that supports 24‑bit color and mouse reporting
- Minimum terminal size: **112 columns × 34 rows** for the current palette and glyph selections

### Data Files

buatae loads palettes and brush character sets from `$HOME/.config/buatae/`. Two files are expected:

- `pal-artiste_520-20x26.txt` – a palette of 520 RGB triplets (space‑separated).
- `chr-deluxe-131x5.bchr` – a glyph grid, each row containing glyphs separated by spaces.
- `buatae_help.ans` – help text (names some unimplemented functions).

You can replace these with your own files. Additional palette/brush files can be added later (menu placeholders exist).

### Basic Controls

| Action | Mouse / Key |
|--------|-------------|
| Draw | **Left‑click** in the drawing area - drag-hold to draw continuously |
| Pick foreground color from image | **Middle‑click** in the drawing area |
| Pick background color from image | **Shift + Middle‑click** (or right‑click on the palette) |
| Select brush | **Click** on a glyph in the brush selector |
| Select foreground color | **Left‑click** on palette |
| Select background color | **Right‑click** on palette |
| Pan the view | **Arrow keys** |
| Open file selector | Press `L` or click “Load” in the menu |
| Save | Press `S` or click “Save” – a status‑line dialog lets you edit the filename |
| Undo | Press `U` or click “Undo” in the menu, **or press Backspace** |
| Redo | Press `R` or click “Redo” in the menu |
| Show help | Press `H` |
| Exit | Press `Q` or `Ctrl+C` |

---

## The Undo/Redo & Shadow File System

One of buatae’s standout features is **persistent, replayable edit history**. Every time you draw, the change is recorded in a **shadow file** that lives next to your artwork. This allows you to:

- Undo/redo edits within a session
- Reopen a file and **continue undoing/redoing** from where you left off (the history is loaded from disk)
- Replay the entire editing session by examining the shadow file

### Shadow File Creation & Naming

- **On first load** of an image (e.g., `foo.ans`), buatae checks for an existing shadow file matching `.foo-<loadtime>-<edittime>.ans` in the same directory.
  - If **none exists**, it creates one immediately, using:
    - `<loadtime>` = current timestamp at load (format `YYYYMMDDHHMMSS`).
    - `<edittime>` = current timestamp (same as load time initially).
  - The new shadow file contains:
    - The **base image** – a full ANSI snapshot of the file *as loaded* (before any edits).
    - A marker `=== EDITS ===` followed by an **empty edit log** (since no edits yet).
- If a shadow file **does exist**, buatae picks the one with the **latest `<edittime>`** (i.e., the most recent editing session) and loads its edit log into memory.

### Edit Log & Undo/Redo

- Each drawing action appends a line to the edit log:
  ```
  col<TAB>row<TAB>old_glyph<TAB>old_fg<TAB>old_bg<TAB>new_glyph<TAB>new_fg<TAB>new_bg
  ```
- The in‑memory array `EDIT_HISTORY` holds these lines. `TOTAL_STEPS` = number of edits, `CURRENT_STEP` = current position (initially at the end).
- **Undo** moves `CURRENT_STEP` backward and applies the old values.
- **Redo** moves forward and applies new values.
- **Making a new edit after undoing** truncates the log (removes all “future” edits) and then appends the new edit.

### Saving

- **Saving to the same filename** (`myfile == IMAGE_FILE`):
  - The image file is overwritten with the **current canvas state** (all visible changes).
  - The existing shadow file is **not touched** – the edit log and history remain exactly as they were.
  - After saving, `TOTAL_STEPS` and `CURRENT_STEP` still refer to the same in‑memory history, so undo/redo continues seamlessly.

- **Saving to a new filename** (`myfile != IMAGE_FILE`):
  - The image file is written to the new name.
  - A **brand‑new shadow file** is created for that new file, with:
    - The **base image** = the original image that was loaded *before any edits* (not the current canvas).
    - The **current edit log** (all edits in `EDIT_HISTORY`, including any that were undone if they haven’t been truncated).
  - The new shadow file gets fresh timestamps: `<loadtime>` = the original load time of the source file, `<edittime>` = now.
  - `IMAGE_FILE` is updated, and subsequent edits will append to this new shadow file.

### Ranges of Edits Available After Save

- **Same‑filename save** – You can still undo/redo **all** edits from the session (and across sessions, because the shadow file retains the full log).
- **New‑filename save** – The new shadow file contains the **full edit history**, so you can undo/redo back to the original loaded state, even after closing and reopening the file later.

### Why This Is Cool

- **Cross‑session undo**: Close the file, reopen it tomorrow, and you can still undo the edits from today.
- **Full replay**: The shadow file is a complete record of every change. You can reconstruct the artwork’s evolution step by step.
- **No hidden state**: Everything is stored in a plain‑text file you can inspect, parse, or even edit manually.

---

## File Selector & Persistent State

The file selector is used for loading images (`.ans`), glyph sets (`.bchr`), and palettes (`.gpl`). It is fully parameterized by an extension pattern.

- **Persistent state**: For each file type (pattern), the selector remembers the last directory, highlighted file index, and page offset. This allows repeated invocations to resume where you left off. The state is stored in an associative array `FILE_SELECTOR_STATE` keyed by `"$pattern|key"`.
- **Paging**: The file list is displayed within the bounds of `BBOX_DRAWWIN`. If there are more files than fit, a page indicator appears, and arrow keys scroll the page.
- **Mouse support**: Clicking a file highlights it; pressing Enter selects it. The click coordinates are mapped to the visible grid using the same geometry as the drawing function.
- **Hidden files**: Dotfiles (names starting with `.`) are excluded from the listing.

---

## Developer Notes

### Architecture

The editor is built around a few core data structures and a clear separation of concerns:

- `IMG_GLYPHS[col,row]` – stores the character at each cell of the canvas.
- `IMG_COLORS[col,row]` – stores the full SGR escape sequence (foreground and background) for that cell.
- `IMG_BASE_GLYPHS`, `IMG_BASE_COLORS` – copies of the original image, used to generate the base section of shadow files.
- `CHR_ARRAY[col,row]` – the brush characters loaded from the `.bchr` file.
- `PAL_ARRAY` – a flat list of RGB triplets (e.g., `"175;175;175"`).
- `BBOX_*` – bounding box arrays that define clickable regions: palette, menu, brush selector, drawing window.
- `EDIT_HISTORY` – in‑memory array of edit strings (same format as shadow file lines).
- `TOTAL_STEPS`, `CURRENT_STEP` – pointers into `EDIT_HISTORY` for undo/redo.

The main loop uses a **state machine** to parse input byte by byte. This avoids the fragility of `read -N` with partial escape sequences. States handle idle, ESC, CSI, X10 mouse, SGR mouse, and CSI parameter parsing.

### Mouse Modes

The editor enables **both** X10 (`\e[?1002h`) and SGR (`\e[?1006h`) mouse reporting. The input parser handles both formats. When entering any modal dialog (save, help, file selector), mouse reporting is **disabled** and input is flushed to avoid stale escape sequences. It is re‑enabled upon return.

### Function Overview

| Function | Purpose | Caveats |
|----------|---------|---------|
| `set_pos` | Move cursor to `col,row` (1‑based). | |
| `draw_bg_border` | Clear screen, draw border and random background pattern. | Must be called after resize. |
| `draw_menu` | Draw the top menu bar. | Position derived from `BBOX_MENUITM`. |
| `draw_chr` | Render the brush selector grid. | Uses `CHR_ARRAY_X`/`CHR_ARRAY_Y`; adapts to variable sizes. |
| `draw_pal` | Render the palette grid. | Expects exactly 520 entries. |
| `draw_drawwin` | Fill the drawing area with a dotted background. | Slow; used only for initial clear. |
| `draw_image` | Render the visible portion of the canvas. | **Must clear the status line first** to avoid leftover text. Also **must ensure `TOTAL_STEPS`/`CURRENT_STEP` are numeric** before printing. |
| `show_fgbg` | Display current foreground/background color swatches. | |
| `load_image` | Parse ANSI files into `IMG_GLYPHS`/`IMG_COLORS`. | The robust `load_image2` is kept separately for future use. |
| `save_image` | Write the entire canvas to a file. | Also manages shadow file creation when saving to a new filename. |
| `process_byte` | Feed one byte into the input state machine. | |
| `parse_x10_mouse` | Decode X10 mouse events (6‑byte). | |
| `parse_sgr_mouse` | Decode SGR mouse events. | |
| `click_item` | Dispatch mouse clicks to UI regions. | Use `(( ... ))` for numeric comparisons, not `[[ ... ]]`. |
| `handle_keys` | Handle single‑key shortcuts. | Backspace (`\x7f` or `\x08`) triggers undo. |
| `list_files` | Populate file list for the selector. | Excludes dotfiles. |
| `file_grid_dims` | Compute grid columns/rows based on `BBOX_DRAWWIN`. | |
| `draw_file_selector` | Draw the file overlay with paging and highlighting. | |
| `file_selector` | Main loop for file browsing. | Stores persistent state per pattern. |
| `save_status_dialog` | Inline filename editor on the status line. | Disables mouse, flushes input, restores after. |
| `draw_help_centered` | Display help file centered on screen. | Strips ANSI for width calculation. |
| `act_help` | Show help, wait for key, restore terminal. | Must restore raw mode, mouse, and cursor. |
| `handle_resize` | Re‑read terminal size, recalc bounding boxes, redraw. | |
| `at_exit` | Restore terminal state and optionally save. | |
| `base_name` | Extract base filename (without extension). | |
| `make_shadow_name` | Build a shadow filename from load time and current time. | |
| `write_shadow_file` | Write base image + edit log to a shadow file. | |
| `load_history` | Load existing shadow file (or create new) and populate edit history. | |
| `append_edit` | Add a new edit to history (and shadow file), truncating redo if necessary. | |
| `undo_edit` | Apply the “old” values of the current step and move back. | |
| `redo_edit` | Apply the “new” values of the next step and move forward. | |

---

## Pitfalls & Lessons Learned (Critical for Successor LLMs)

1. **Arithmetic Expansion**  
   - Use `$(( ... ))` for arithmetic.
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
   - Always disable mouse reporting (`\e[?1002l`) before any modal dialog and re‑enable (`\e[?1002h` and `\e[?1006h`) afterward.

5. **Status Line Overdraw**  
   - `draw_image` must clear the entire status line (e.g., `printf "%*s" $width ""`) before writing new text; otherwise residual characters appear.

6. **ANSI Parsing**  
   - The original `load_image` used `IFS=$'\e' read -a fields`; this breaks when an SGR sequence is followed directly by text without a reset. `load_image2` is more robust. It is kept as a separate utility for future integration.

7. **Resize Handling**  
   - Always re‑read `tput cols/lines` after `SIGWINCH`. Recalculate bounding boxes and redraw all UI elements. Use a flag (`RESIZE_NEEDED`) to avoid blocking in the signal handler.

8. **File Saving & Shadow Files**  
   - Filename validation regex is strict (`^[a-zA-Z0-9._/-]+$`). If users need spaces, adjust the regex accordingly. Trim leading/trailing whitespace before saving.  
   - When saving to a new filename, the shadow file is regenerated with the *base image* (the image as loaded) and the current edit history. This ensures the edit log remains consistent.

9. **Color String Handling**  
   - Always store RGB triplets without a trailing `m` (e.g., `175;175;175`). Append `m` only when building the full SGR sequence (`\e[38;2;${r};${g};${b}m`). This avoids double‑`m` artifacts.

10. **`TOTAL_STEPS` / `CURRENT_STEP` Numeric Integrity**  
   - **Always** ensure these variables are defined and numeric before using them in arithmetic or `printf`. Use `: "${TOTAL_STEPS:=0}"` and `: "${CURRENT_STEP:=0}"` at the start of functions that print them, and also coerce with `$(( ... + 0 ))` if there's any risk of a non‑numeric string.
   - A common mistake is writing `CURRENT_STEP=TOTAL_STEPS` (missing `$`), which assigns the literal string `TOTAL_STEPS` instead of its value. This causes `printf: TOTAL_STEPS: invalid number`. Always use `CURRENT_STEP=$TOTAL_STEPS` or `(( CURRENT_STEP = TOTAL_STEPS ))`.

11. **File Selector Geometry**  
   - The horizontal centering uses `start_x = draw_x + (draw_w - FILE_NUM_COLS * max_w) / 2`. The same `max_w` and `start_x` must be used in both `draw_file_selector` and the mouse‑click mapping in `file_selector`. Inconsistent `max_w` (e.g., computing only over visible files) causes an off‑by‑one column shift.

12. **`local IFS=...` Syntax Error**  
   - In SGR mouse parsing, `local IFS=';' read -ra parts <<< "$data"` is invalid Bash. Split it into:
     ```bash
     local -a parts
     IFS=';' read -ra parts <<< "$data"
     ```

---

## Contributing

This project is a work in progress. If you’d like to contribute feel free to file a PR or an issue.

This editor, like most ANSI‑art editors, eschews some common graphical‑UI patterns, but attempts have been made to keep major functions un‑nested and intuitive. The code is deliberately simple and hackable – it’s Bash, after all.

## License

MIT

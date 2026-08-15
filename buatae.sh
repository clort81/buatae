#!/usr/bin/env bash
# buatae.sh - ANSI Art Editor with persistent undo/redo history
# Written by: clort; later help by deepseek-v4
# Developed between: 2015-2026

#set -eu # Uncomment for strict error checking (may break some parts)

# ----------------------------------------------------------------------
# Global variables and constants
# ----------------------------------------------------------------------
_STTY=$(stty -g)        # Save current terminal setup
ESC=$'\e'  
TERMCOLS=$(tput cols)   # Terminal columns (refreshed on resize)
TERMROWS=$(tput lines)  # Terminal rows
TERM_MIN_LINES=34
TERM_MIN_COLUMNS=112

declare -g bd_datadir="$HOME/.config/buatae/"
declare -g PAL_NAME="artiste_520.gpl"
declare -g PAL_SNAME="Default_Pal"
declare -g HELP_NAME="buatae_help.ans"
declare -g PAL_ARRAY_X=20
declare -g PAL_ARRAY_Y=26
declare -g -A CHR_ARRAY         # Brushes (glyphs)
declare -g PAL_ARRAY            # Palette colors
declare -g CHR_NAME="chr-deluxe-36x4.chr"
declare -g CHR_MAX_COLS=0
declare -g CHR_ARRAY_X=80
declare -g CHR_ARRAY_Y=4
declare -g -A IMAGE_BASE        # (unused? kept for compatibility)
declare -g -A CMD_BUFFER        # Undo/redo buffer (placeholder)
declare -g -A IMG_GLYPHS        # Image glyphs
declare -g -A IMG_COLORS        # Image colors
declare -g IMG_NUMCOLS
declare -g IMG_WIDTH=0
declare -g IMG_HEIGHT=0
declare -g -a parts=()
declare -g DRAWWIN_OFFX=0
declare -g DRAWWIN_OFFY=0
declare -g -A IMG_BASE_GLYPHS   # keep copy of original image glyphs for shadow edit . file
declare -g -A IMG_BASE_COLORS   # keep copy of original image colors for shadow edit . file
declare -g FILE_PAGE_START=0    # Global variable for page offset
declare -g -A FILE_SELECTOR_STATE=()
declare -g LOAD_DIR="$PWD"          # for .ans files
declare -g GLYPH_DIR="$bd_datadir"  # for .chr files
declare -g PALETTE_DIR="$bd_datadir" # for .gpl files

#DEBUG_LOG="./debug.log"
#: > "$DEBUG_LOG"   # clear log at start


# Flag for resize handling
RESIZE_NEEDED=0

# Terminal size check
if [[ "$TERMROWS" -lt "$TERM_MIN_LINES" ]] || [[ "$TERMCOLS" -lt "$TERM_MIN_COLUMNS" ]]; then
        echo "ERROR!"
        echo "Terminal size is below minimum required: $TERM_MIN_COLUMNS columns and $TERM_MIN_LINES rows"
        exit 1
fi

# Command line handling
if [[ $# -eq 0 ]]; then
    IMAGE_FILE="$bd_datadir/default.ans"
elif [[ $1 == "-h" || $1 == "--help" ]]; then
        printf "\nUsage:"
        printf "\t$0 textfile.\n"
        printf "\n\tRequires a 24-bit color terminal min 120 columns, 40 rows\n"
        printf "\n\tloaded textfile will be backup'd to ./tempfiles/filename+date.ext\n\n"
        printf "\t\tHit <H> for usage instructions to edit!\n"
        printf "\t\tHit <Ctrl-C> any time to quit the program.\n\n"
        exit 1
else
        IMAGE_FILE="$1"
fi

# Global variables for file selector
declare -a FILE_LIST=()
declare -g SELECTED_FILE=""
FILE_INDEX=0
FILE_DIR="$PWD"
IN_FILE_SELECTOR=0
FILE_NUM_COLS=1
FILE_NUM_ROWS=1

# ----------------------------------------------------------------------
# Undo/redo history variables
# ----------------------------------------------------------------------
declare -a EDIT_HISTORY=()   # Each element: "col\trow\toldglyph\toldfg\toldbg\tnewglyph\tnewfg\tnewbg"
TOTAL_STEPS=0
CURRENT_STEP=0
SHADOW_FILE=""
LOAD_TIME=$(date +%Y%m%d%H%M%S)

# ----------------------------------------------------------------------
# Terminal initialization
# ----------------------------------------------------------------------
printf "\e[2J"          # Clear screen
stty -echo -icanon      # Disable echo and line buffering
# Mouse tracking: enable X10 mode (default) and SGR mode (better coordinates).
# Parser handles both, so we can fall back if terminal doesn't support SGR.
printf "\e[?1002h"   # Enable cell motion mouse tracking (X10)
#printf "\e[?1006h"   # Enable SGR extended coordinates
printf "\e[?25l"     # Hide cursor

# Color constants (ANSI 24-bit)
BGP='\e[48;2;'
FGP='\e[38;2;'
COL_END=$"\e""[0m"
COL_GAMSCR_FG="\e[38;2;8;19;75m"
COL_GAMSCR_BG="\e[48;2;0;0;0m"
COL_GAMSCR_BR="\e[38;2;0;109;139m"
COL_BLACK_BG="\e[48;0;0;0m"
COL_CHRROW_BG="\e[48;2;20;20;20m"
COL_CLKBOR_FG="\e[38;2;0;5;80m"
COL_CLKBOR_BG="\e[48;2;0;29;97m"
COL_TXTBOR_BG="\e[48;2;0;5;80m"
COL_ORABOR_FG="\e[38;2;180;117;92m"
COL_CHR_FG="\e[38;2;200;200;200m"
COL_CHR_BG="\e[48;2;0;0;0m"
COL_DKGREY_BG="\e[48;2;25;25;25m"
COL_DKGREY_FG="\e[38;2;25;25;25m"
COL_CURBRUSH="${COL_CHR_FG}${COL_CHR_BG}"
COL_MENU_DRK="\e[38;2;128;128;128m"
COL_MENU_LIG="\e[38;2;198;198;198m"
COL_MENU_MED="\e[38;2;175;175;175m"

# Bounding boxes (adjusted on resize)
BBOX_PALETTE=(5 3 25 28)
BBOX_MENUITM=(0 0 0 0)    # Gets set after load_palette
BBOX_BRUSHES=($((TERMCOLS-60)) $((LINES-4)) $((TERMCOLS-1)) $((LINES-1)))
BBOX_DRAWWIN=( $(( ${BBOX_PALETTE[3]} - 2 )) 3 $((TERMCOLS-2)) $(( ${BBOX_BRUSHES[1]} - 4 )) )

# User state variables
KEYCMD=""
USERHIT=""
MOUSEBT=""
BRUSH="X"
MYFG="175;175;175"
MYBG="5;55;25"
SAVED="Y"

# ----------------------------------------------------------------------
# Function definitions
# ----------------------------------------------------------------------

# Get/set file selector state
function fs_state_set() {
    local pattern="$1" key="$2" value="$3"
    FILE_SELECTOR_STATE["$pattern|$key"]="$value"
}
function fs_state_get() {
    local pattern="$1" key="$2"
    echo "${FILE_SELECTOR_STATE["$pattern|$key"]:-}"
}

# Position cursor: set_pos <col> (x) <row> (y)
function set_pos() {
        echo -en "\e[$2;$1f"         # Note that esc[{row};{column}]h suposedly works too
}

# Show mouse coordinates (debug)
function show_pos() {
        printf "x,y = %3d,%3d" $X $Y
}

# Show current foreground/background colors – now below palette
function show_fgbg() {   
        (( myxpos=3 ))
        (( myypos=BBOX_PALETTE[3]+3 ))
        set_pos $myxpos $myypos 
        printf "${COL_TXTBOR_BG}${COL_MENU_LIG}f${COL_MENU_DRK}G ${COL_MENU_LIG}b${COL_MENU_DRK}G\e[0m"
        set_pos $myxpos $((myypos+1))
        printf "${BGP}${MYFG}m  ${COL_TXTBOR_BG} ${BGP}${MYBG}m  ${COL_END}\e[0m"
        set_pos $myxpos $((myypos+2))
        printf "${BGP}${MYFG}m  ${COL_TXTBOR_BG} ${BGP}${MYBG}m  ${COL_END}\e[0m"
        set_pos $myxpos $((myypos+3))
        printf "${COL_TXTBOR_BG}${COL_MENU_LIG}x${COL_MENU_DRK}chng\e[0m"
}

# Draw the drawing area background (dotted grid)
function draw_drawwin() {
        for ((dwy=${BBOX_DRAWWIN[1]}; dwy<=${BBOX_DRAWWIN[3]}; dwy++)); do
                set_pos ${BBOX_DRAWWIN[0]} ${dwy}
                row="${COL_CHR_BG}${COL_DKGREY_FG}"
                for ((dwx=${BBOX_DRAWWIN[0]}; dwx<=${BBOX_DRAWWIN[2]}; dwx++)); do
                        row+="."
                done
                printf "${row}"
        done
}

# ----------------------------------------------------------------------
# ANSI SGR parser for load_image
# ----------------------------------------------------------------------
# Parses an SGR sequence (without the ESC[ and without trailing m) and
# updates lastfg/lastbg variables.
function parse_sgr_sequence() {
        local seq="$1"
        local fgbg="${seq%%;*}"
        local numfields
        local semis=${seq//[!;]/}
        numfields=$(( ${#semis}+1 ))
        case $numfields in
        1)
                # Reset or simple color (30-37, 40-47) – we ignore for now
                # Could be handled but we'll just reset both.
                lastfg=""
                lastbg=""
                ;;
        5)
                # 38;5;N or 48;5;N
                case $fgbg in
                38) lastfg="$seq" ;;
                48) lastbg="$seq" ;;
                *) # other, ignore
                        ;;
                esac
                ;;
        10)
                # 38;2;R;G;B;48;2;R;G;B (10 fields)
                # Split and assign accordingly
                local -a addr
                IFS=';' read -ra addr <<< "$seq"
                if [[ "${addr[0]}" == "38" ]]; then
                        # first half is foreground, second half is background
                        lastfg="${addr[0]};${addr[1]};${addr[2]};${addr[3]};${addr[4]}"
                        lastbg="${addr[5]};${addr[6]};${addr[7]};${addr[8]};${addr[9]}"
                elif [[ "${addr[0]}" == "48" ]]; then
                        # first half is background, second half is foreground
                        lastbg="${addr[0]};${addr[1]};${addr[2]};${addr[3]};${addr[4]}"
                        lastfg="${addr[5]};${addr[6]};${addr[7]};${addr[8]};${addr[9]}"
                fi
                ;;
        *)
                # Unknown sequence – ignore
                ;;
        esac
}

# Load image from ANSI file
function load_image() {
        current_file="$1"
        local current_file="$1"
        if [[ ! -f $current_file ]]; then
                set_pos 1 $((TERMROWS-0))
                printf ${COL_END}
                printf "Error! File %s not found.\n" $current_file
                exit
        fi
        ESC=$'\e'
        IMG_WIDTH=0; IMG_HEIGHT=0
        myfg=""; mybg=""
        mycolor=""
        lastfg=""; lastbg=""
        myrow=0; mycol=0
        while IFS= read -r line
        do
                fg_counter=0; bg_counter=0
                oldifs=$IFS
                IFS=$'\e' read -a fields <<< "${line}"
                for (( i = 0; i < ${#fields[@]}; i++ ))
                do
                        token=${fields[$i]}
                        if [[ -z "$token" ]]; then
                                continue
                        fi
                        if [[ ${token:0:1} == "[" ]]; then
                                # Extract parameter string up to the FIRST 'm'
                                # (not last 'm', which caused corruption when text contains 'm')
                                tokhead="${token%%m*}"
                                tokhead="${tokhead#[}"   # remove leading '['
                                # Text after the first 'm' is the glyph tail
                                toktail="${token#*m}"
                                old_ifs="$IFS"; IFS=';'
                                semis=${tokhead//[!;]/}; numfields=$(( ${#semis}+1 ))
                                IFS="$old_ifs"
                                fgbg="${tokhead%%;*}"
                                case $numfields in
                                5)
                                        case $fgbg in
                                        38) # foreground
                                                myfg="${tokhead}"
                                                mycolor="${myfg};${lastbg}"
                                                lastfg="${myfg}"
                                                ;;
                                        48) # background
                                                mybg="${tokhead}"
                                                mycolor="${lastfg};${mybg}"
                                                lastbg="${mybg}"
                                                ;;
                                        *)
                                                echo "Error! Invalid value for fgbg in single-color token"
                                                exit
                                                ;;
                                        esac
                                        ;;
                                10)
                                        case $fgbg in
                                        38)
                                                old_ifs="$IFS"
                                                IFS=';' read -ra ADDR <<< "$tokhead"
                                                IFS="$old_ifs"
                                                firsthalf="${ADDR[@]:0:5}"; firsthalf=${firsthalf// /;}
                                                secondhalf="${ADDR[@]:5:5}"; secondhalf=${secondhalf// /;}
                                                mycolor="${tokhead}"
                                                lastfg=${firsthalf}
                                                lastbg=${secondhalf}
                                                ;;
                                        48)
                                                old_ifs="$IFS"
                                                IFS=';' read -ra ADDR <<< "$tokhead"
                                                IFS="$old_ifs"
                                                firsthalf="${ADDR[@]:0:5}"; firsthalf=${firsthalf// /;}
                                                secondhalf="${ADDR[@]:5:5}"; secondhalf=${secondhalf// /;}
                                                mycolor="${secondhalf};${firsthalf}"
                                                lastfg=${secondhalf}
                                                lastbg=${firsthalf}
                                                ;;
                                        *)
                                                echo "Error! Invalid value for fgbg in dual-color token"
                                                exit
                                                ;;
                                        esac
                                        ;;
                                1)
                                        continue
                                        ;;
                                *)
                                        echo "Invalid input file!"
                                        exit
                                        ;;
                                esac
                        else
                                toktail="$token"
                        fi
                        for (( j = 0; j < ${#toktail}; j++ ))
                        do
                                glyph=${toktail:$j:1}
                                IMG_GLYPHS[$mycol,$myrow]=$glyph
                                IMG_COLORS[$mycol,$myrow]="$ESC""[$lastfg""m""$ESC""[$lastbg""m"
                                ((++mycol))
                        done
                        continue
                done
                if (( $mycol > $IMG_WIDTH )); then
                        IMG_WIDTH=$mycol
                fi
                ((++IMG_HEIGHT))
                let "myrow++"
                mycol=0
        done < "$current_file"
        for key in "${!IMG_GLYPHS[@]}"; do
            IMG_BASE_GLYPHS["$key"]="${IMG_GLYPHS[$key]}"
            IMG_BASE_COLORS["$key"]="${IMG_COLORS[$key]}"
        done
}


# Draw the image inside the drawing window
function draw_image() {
    TOTAL_STEPS=$(( ${TOTAL_STEPS:-0} + 0 ))     # Fancy "ensure it's an integer"
    CURRENT_STEP=$(( ${CURRENT_STEP:-0} + 0 ))   # Fancy "ensure it's an integer"


    local vis_row vis_col src_row src_col
    sleep 0.05s
    # Clear status line by printing spaces over full width
    set_pos ${BBOX_DRAWWIN[0]} ${BBOX_DRAWWIN[3]}
    printf "${COL_END}"   # reset attributes
    printf "%*s" $(( ${BBOX_DRAWWIN[2]} - ${BBOX_DRAWWIN[0]} + 1 )) ""

    # Now print status
    set_pos $((${BBOX_DRAWWIN[0]}+1)) $((${BBOX_DRAWWIN[3]}))
    DRAWWID=$(( ${BBOX_DRAWWIN[2]} - ${BBOX_DRAWWIN[0]} ))
    DRAWHGT=$(( ${BBOX_DRAWWIN[3]} - ${BBOX_DRAWWIN[1]} ))
    local display_name
    display_name=$(truncate_path_display "$IMAGE_FILE")
    printf "${COL_END}File: %s WID: %s HGT: %s Step: %d/%d  " \
           "$display_name" "$IMG_WIDTH" "$IMG_HEIGHT" \
           "$CURRENT_STEP" "$TOTAL_STEPS" \
    # Clamp offsets to valid range (prevent negative or out-of-bounds)
    (( DRAWWIN_OFFX < 0 )) && DRAWWIN_OFFX=0
    (( DRAWWIN_OFFY < 0 )) && DRAWWIN_OFFY=0
    (( DRAWWIN_OFFX >= IMG_WIDTH )) && DRAWWIN_OFFX=$(( IMG_WIDTH - 1 ))
    (( DRAWWIN_OFFY >= IMG_HEIGHT )) && DRAWWIN_OFFY=$(( IMG_HEIGHT - 1 ))

    # Draw only the visible region
    for ((vis_row=0; vis_row<DRAWHGT; vis_row++)); do
        src_row=$(( DRAWWIN_OFFY + vis_row ))
        if (( src_row >= IMG_HEIGHT )); then break; fi   # stop if source row past image bottom

        set_pos ${BBOX_DRAWWIN[0]} $(( BBOX_DRAWWIN[1] + vis_row ))
        for ((vis_col=0; vis_col<DRAWWID; vis_col++)); do
            src_col=$(( DRAWWIN_OFFX + vis_col ))
            if (( src_col >= IMG_WIDTH )); then break; fi   # stop if source col past image right
            echo -n "${IMG_COLORS[$src_col,$src_row]}"
            echo -n "${IMG_GLYPHS[$src_col,$src_row]}"
        done
        echo -n $'\e'"[0m"
    done
}

# Count unique colors (unused)
function img_numcols() {
        for ((myrow = 0; myrow < IMG_HEIGHT-1; ++myrow)); do
                for ((mycol = 0; mycol < IMG_WIDTH; ++mycol)); do
                        echo -n "${IMG_COLORS[$mycol,$myrow]}"
                done
                echo -n $'\e'"[0m"
        done
}

# Split string by pattern (utility)
function split_substr() {
        local pat=$1 str=$2 split='' c=''
        local -i sanity=${#str}
        parts=()
        for (( i=0; i<${#pat}; i++ )); do
                c=${pat:${i}:1}
                [[ $c =~ [$^|()\.*+?[]|\] ]] && split+='\'
                split+=$c
        done
        while (( ${#str} )) && [[ $str =~ ${split}(.*) ]]
        do
                parts+=("${str%%${BASH_REMATCH[0]}}")
                str=${BASH_REMATCH[1]}
                (( sanity-- )) || exit 99
        done
        (( ${#str} )) && parts+=("$str")
        declare -p parts
}

# Beep (stub if no beep program)
function mybeep() {
        $bd_datadir/beep 2>/dev/null || true
}

# Read a single character (blocking)
read_char() {
        eval "$1=\$(dd bs=1 count=1 2>/dev/null)"
}

# Save image to file
function save_image() {
        local myfile="$1"
        local filename_regex='^[a-zA-Z0-9._/-]+$'
        if [[ ! $myfile =~ $filename_regex ]]; then
                show_statsR '"Error: %s is not a valid filename." "$myfile"'
                return
        fi
        if [[ -e $myfile ]]; then
                printf "\e[?1002l"      # disable mouse
                show_statsR '" File: %s exists, overwrite? y/N/r:       " "$myfile"'
                response=""
                read_char response
                printf "\e[?1002h"      # re-enable mouse
                if [[ $response == 'Y' ]] || [[ $response == 'y' ]]; then
                        show_statsR '"Yes    "'
                        rm -f "$myfile"
                elif [[ $response == 'R' ]] || [[ $response == 'r' ]]; then
                        read myfile
                else
                        show_statsR '"No     "'
                        #mybeep
                        return
                fi
        else
                touch "$myfile"
                if [[ $? != 0 ]]; then
                        show_statsR '"Cannot create: %s!" "$myfile"'
                        return
                fi
        fi
        # Save entire image (current state)
        for ((myrow = 0; myrow < IMG_HEIGHT; ++myrow)); do
                for ((mycol = 0; mycol < IMG_WIDTH; ++mycol)); do
                        printf "${IMG_COLORS[$mycol,$myrow]}" >> "$myfile"
                        echo -n "${IMG_GLYPHS[$mycol,$myrow]}" >> "$myfile"
                done
                echo $'\e'"[0m" >> "$myfile"
        done

        # If saving to a new filename, update shadow file
        if [[ "$myfile" != "$IMAGE_FILE" ]]; then
                IMAGE_FILE="$myfile"
                # Create a new shadow file with the base image and current edit history
                SHADOW_FILE=$(make_shadow_name)
                write_shadow_file "$SHADOW_FILE"
        fi

        set_pos $((${BBOX_DRAWWIN[0]}+2)) $((${BBOX_DRAWWIN[3]}+0))
        printf " File saved..."
        SAVED="Y"

        # Sync step counters with the current history array
        TOTAL_STEPS=${#EDIT_HISTORY[@]}
        if (( CURRENT_STEP > TOTAL_STEPS )); then
            CURRENT_STEP=$TOTAL_STEPS
        fi

}

# Undo/redo history functions
# ----------------------------------------------------------------------

# Get base name without extension
function base_name() {
    local f="${1##*/}"
    echo "${f%.*}"
}

# Construct shadow filename using LOAD_TIME and current time
function make_shadow_name() {
    local base=$(base_name "$IMAGE_FILE")
    local now=$(date +%Y%m%d%H%M%S)
    echo ".${base}-${LOAD_TIME}-${now}.ans"
}

# Write current image and edit log to shadow file
function write_shadow_file() {
    local shadow="$1"
    : > "$shadow"
    for ((myrow = 0; myrow < IMG_HEIGHT; ++myrow)); do
        for ((mycol = 0; mycol < IMG_WIDTH; ++mycol)); do
            printf "${IMG_BASE_COLORS[$mycol,$myrow]}" >> "$shadow"
            echo -n "${IMG_BASE_GLYPHS[$mycol,$myrow]}" >> "$shadow"
        done
        echo $'\e'"[0m" >> "$shadow"
    done
    echo "=== EDITS ===" >> "$shadow"
    for edit in "${EDIT_HISTORY[@]}"; do
        echo "$edit" >> "$shadow"
    done
}

# Load history from shadow file if exists, else create new
function load_history() {
    local base=$(base_name "$IMAGE_FILE")
    local pattern=".${base}-*.ans"
    local candidates=()
    local f
    # Find all matching shadow files
    for f in $pattern; do
        [[ -e "$f" ]] && candidates+=("$f")
    done
    if (( ${#candidates[@]} == 0 )); then
        # No shadow file, create one
        SHADOW_FILE=$(make_shadow_name)
        write_shadow_file "$SHADOW_FILE"
        TOTAL_STEPS=0
        CURRENT_STEP=0
        return
    fi
    # Pick the one with the latest edit time (second timestamp)
    local latest=""
    local latest_time=0
    for f in "${candidates[@]}"; do
        # extract edit time: after second '-', before .ans
        local edit_time="${f##*-}"
        edit_time="${edit_time%.ans}"
        if (( 10#$edit_time > latest_time )); then
            latest_time=10#$edit_time
            latest="$f"
        fi
    done
    SHADOW_FILE="$latest"
    # Read edit log from shadow file (after === EDITS ===)
    local in_edits=0
    local line
    EDIT_HISTORY=()
    while IFS= read -r line; do
        if [[ "$in_edits" -eq 1 ]]; then
            [[ -n "$line" ]] && EDIT_HISTORY+=("$line")
        elif [[ "$line" == "=== EDITS ===" ]]; then
            in_edits=1
        fi
    done < "$SHADOW_FILE"
    TOTAL_STEPS=${#EDIT_HISTORY[@]}
    CURRENT_STEP=$TOTAL_STEPS
}

# Append an edit to history (and truncate if we had undone)
function append_edit() {
    local x="$1" y="$2" oldg="$3" oldfg="$4" oldbg="$5" newg="$6" newfg="$7" newbg="$8"
    # If we have undone, truncate future edits
    if (( CURRENT_STEP < TOTAL_STEPS )); then
        EDIT_HISTORY=("${EDIT_HISTORY[@]:0:CURRENT_STEP}")
        TOTAL_STEPS=${#EDIT_HISTORY[@]}
    fi
    EDIT_HISTORY+=( "$x"$'\t'"$y"$'\t'"$oldg"$'\t'"$oldfg"$'\t'"$oldbg"$'\t'"$newg"$'\t'"$newfg"$'\t'"$newbg" )
    TOTAL_STEPS=${#EDIT_HISTORY[@]}
    CURRENT_STEP=$TOTAL_STEPS
    # Write to shadow file (rewrite entire file to keep it consistent)
    write_shadow_file "$SHADOW_FILE"
}

# Undo one step
function undo_edit() {
    if (( CURRENT_STEP > 0 )); then
        ((CURRENT_STEP--))
        local edit="${EDIT_HISTORY[$CURRENT_STEP]}"
        IFS=$'\t' read -ra f <<< "$edit"
        local x="${f[0]}" y="${f[1]}" oldg="${f[2]}" oldfg="${f[3]}" oldbg="${f[4]}"
        IMG_GLYPHS[$x,$y]="$oldg"
        IMG_COLORS[$x,$y]="$ESC[38;2;${oldfg}m$ESC[48;2;${oldbg}m"
        draw_image
    fi
}

# Redo one step
function redo_edit() {
    if (( CURRENT_STEP < TOTAL_STEPS )); then
        local edit="${EDIT_HISTORY[$CURRENT_STEP]}"
        IFS=$'\t' read -ra f <<< "$edit"
        local x="${f[0]}" y="${f[1]}" newg="${f[5]}" newfg="${f[6]}" newbg="${f[7]}"
        IMG_GLYPHS[$x,$y]="$newg"
        IMG_COLORS[$x,$y]="$ESC[38;2;${newfg}m$ESC[48;2;${newbg}m"
        ((CURRENT_STEP++))
        draw_image
    fi
}

# Display glyph load error on status line, wait, and restore UI
function show_chr_error() {
    local msg="$1"
    printf "\e[?1002l"
    IFS= read -r -t 0 -n 1000 dummy 2>/dev/null || true
    set_pos ${BBOX_DRAWWIN[0]} ${BBOX_DRAWWIN[3]}
    printf "%*s" $(( ${BBOX_DRAWWIN[2]} - ${BBOX_DRAWWIN[0]} + 1 )) ""
    set_pos ${BBOX_DRAWWIN[0]} ${BBOX_DRAWWIN[3]}
    printf "\e[38;2;255;255;255;48;2;255;0;0;5mERROR: %s\e[0m" "$msg"
    sleep 3
    handle_resize
    printf "\e[?1002h"
}

function load_chr() {
    local chr_file="$1"
    # If the given path doesn't exist, try the data directory
    if [[ ! -f "$chr_file" && -f "$bd_datadir/$1" ]]; then
        chr_file="$bd_datadir/$1"
    fi
    if [[ ! -f "$chr_file" ]]; then
        show_chr_error "Glyph file not found: $chr_file"
        return 1
    fi
    local line
    local max_cols=0
    local nrows=0

    # First pass: count rows and max columns
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( nrows++ ))
        local -a fields
        read -ra fields <<< "$line"
        local ncols=${#fields[@]}
        (( ncols > max_cols )) && max_cols=$ncols
    done < "$chr_file"

    if (( nrows == 0 || max_cols == 0 )); then
        show_chr_error "Empty or invalid glyph file: $chr_file"
        return 1
    fi

    CHR_MAX_COLS=$max_cols
    CHR_ARRAY_Y=$nrows
    CHR_ARRAY_X=$max_cols

    # Second pass: store glyphs
    local row=0 col=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        local -a fields
        read -ra fields <<< "$line"
        col=0
        for glyph in "${fields[@]}"; do
            [[ -z "$glyph" ]] && continue
            CHR_ARRAY["$col,$row"]="$glyph"
            (( col++ ))
        done
        (( row++ ))
    done < "$chr_file"

    # Recompute all bounding boxes (brush, palette, draw window, menu)
    recalc_boxes
    return 0
}

# Draw brush selector box
function draw_chr() {
    local column_start=$(( TERMCOLS - CHR_ARRAY_X*3 - 2 ))
    local row_start=$(( TERMROWS - (2*CHR_ARRAY_Y) + 1 ))
    declare xindex=""
    local arrow=0; local arcol=0; local chr=""

    # Top border
    set_pos $((column_start-2)) $((row_start-4))
    echo -ne "${COL_CLKBOR_FG}${COL_CLKBOR_BG}$(printf '%0.s▀' $(seq 0 $((CHR_ARRAY_X*3+3))))\e[0m"

    # Index row
    xindex+="$(printf '%0.c  ' {a..z} $(seq 1 9))"; xindex+="0 "
    outindex=""
    for ((arcol=0; arcol<CHR_ARRAY_X; arcol++)); do
        outindex+=${xindex:$((arcol*3)):1}
        outindex+="  "
    done
    set_pos $((column_start-2)) $((row_start-3))
    printf "${COL_CHR_FG}${COL_CLKBOR_BG}    "; echo -n "${outindex}"; printf "\e[0m"

    # Dark separator
    set_pos $column_start $((row_start-2))
    echo -ne "${COL_DKGREY_BG}$(printf '%0.s ' $(seq 0 $((CHR_ARRAY_X*3+1))))\e[0m"
    set_pos $((column_start-2)) $((row_start-2))
    printf "${COL_CHR_FG}${COL_CLKBOR_BG}  "

    # Glyph rows
    for ((arrow=0; arrow<CHR_ARRAY_Y; arrow++)); do
        set_pos $((column_start-2)) $((row_start+(2*arrow+1)-2))
        printf "${COL_CHR_FG}${COL_CLKBOR_BG}  "
        row="${COL_CHR_BG}${COL_CHR_FG} "
        for ((arcol=0; arcol<CHR_ARRAY_X; arcol++)); do
            row+=" "${CHR_ARRAY["$arcol,$arrow"]}" "
        done
        row+=" \e[0m"
        set_pos $((column_start-1)) $((row_start+(2*arrow+1)-2))
        printf "$((arrow+1))${row}"

        set_pos $((column_start-2)) $((row_start+(2*arrow+1)-1))
        printf "${COL_CHR_FG}${COL_CLKBOR_BG}  "
        set_pos $column_start $((row_start+(2*arrow+1)-1))
        echo -ne "${COL_DKGREY_BG}$(printf '%0.s ' $(seq 0 $((CHR_ARRAY_X*3+1))))\e[0m"
    done

    # Current brush indicator
    local bx=$((column_start-3))
    local by=$((row_start-4))
    set_pos $bx $by
    echo -ne "${COL_TXTBOR_BG}${COL_ORABOR_FG}╭───╮\e[0m"
    set_pos $bx $((by+1))
    echo -ne "${COL_TXTBOR_BG}${COL_ORABOR_FG}│${COL_BLACK_BG}${COL_MENU_LIG} ${BRUSH} ${COL_TXTBOR_BG}${COL_ORABOR_FG}│\e[0m"
    set_pos $bx $((by+2))
    echo -ne "${COL_TXTBOR_BG}${COL_ORABOR_FG}╰───╯\e[0m"
}

### 1. Parse .gpl File
#- Read file line by line.
#- Skip lines that are empty or start with `#`.
#- Detect `Columns: N` header; extract `N`.
#- After header, parse lines containing three integers (R G B) – ignore trailing comments.
#- Store colors as `"R;G;B"` in global `PAL_ARRAY`.
#
#### 2. Determine Palette Grid Dimensions
#- **Columns** (`PAL_ARRAY_X`):  
#  - If `Columns` header exists and is between 1 and 36, use it.  
#  - Otherwise, derive a rectangular shape: choose width = `ceil(sqrt(num_entries / 2))` to make the palette roughly twice as tall as wide.
#- **Rows** (`PAL_ARRAY_Y`): `ceil(num_entries / PAL_ARRAY_X)`.
#
#### 3. Update Bounding Boxes
#- Recompute `BBOX_PALETTE` based on new dimensions:  
#  `BBOX_PALETTE=(x1 y1 x2 y2)` where `x1=5`, `y1=3`, `x2=x1+PAL_ARRAY_X-1`, `y2=y1+PAL_ARRAY_Y-1`.
#- Recompute `BBOX_MENUITM` and `BBOX_DRAWWIN` to account for the new palette width (right edge).  
#  - Draw window left edge = `BBOX_PALETTE[2] + 1`.
#- Keep brush window placement unchanged.
#
#### 4. Update `draw_pal` to Render Variable‑Sized Palette
#- Print column labels (a–z, 0–9) across the top, one per column.
#- Print row labels (a–z, 0–9) on the left, one per row.
#- Render each color as a full block character (`█`) with the corresponding background color.
#- Display the palette name from the `Name:` header (if present) centered at the bottom.
#
#### 5. Error Handling
#- If file missing or no colors found, print `"Bad palette! <reason>"` on the status line and keep the previous palette.
#
# Display palette load error on status line, wait, and restore UI
function show_pal_error() {
    local msg="$1"
    printf "\e[?1002l"   # disable mouse
    IFS= read -r -t 0 -n 1000 dummy 2>/dev/null || true   # flush input
    set_pos ${BBOX_DRAWWIN[0]} ${BBOX_DRAWWIN[3]}
    printf "%*s" $(( ${BBOX_DRAWWIN[2]} - ${BBOX_DRAWWIN[0]} + 1 )) ""   # clear status line
    set_pos ${BBOX_DRAWWIN[0]} ${BBOX_DRAWWIN[3]}
    printf "\e[38;2;255;255;255;48;2;255;0;0;5mERROR: %s\e[0m" "$msg"
    sleep 3
    handle_resize          # redraw entire editor
    printf "\e[?1002h"
}
# ----------------------------------------------------------------------
# Load GIMP .gpl palette file
# ----------------------------------------------------------------------
function load_pal() {
    local pal_file="$1"
    # If the given path doesn't exist, try the data directory
    if [[ ! -f "$pal_file" && -f "$bd_datadir/$1" ]]; then
        pal_file="$bd_datadir/$1"
    fi
    local line
    local columns=0
    local name=""
    local count=0
    local left_bound=0
    local drawwin_width=0
    local menu_width=86
    local menu_offset=0

    # ---------- PASS 1: metadata + count ----------
    if [[ ! -f "$pal_file" ]]; then
        show_pal_error "Palette file not found: $pal_file"
        return 1
    fi

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^Name:[[:space:]]*(.*) ]]; then
            name="${BASH_REMATCH[1]}"
            name="${name%;}"
            continue
        fi
        if [[ "$line" =~ ^Columns:[[:space:]]*([0-9]+) ]]; then
            columns="${BASH_REMATCH[1]}"
            continue
        fi
        # Count lines that start with three numbers
        read -ra fields <<< "$line"
        if (( ${#fields[@]} >= 3 )) && [[ ${fields[0]} =~ ^[0-9]+$ ]] && \
           [[ ${fields[1]} =~ ^[0-9]+$ ]] && [[ ${fields[2]} =~ ^[0-9]+$ ]]; then
            ((count++))
        fi
    done < "$pal_file"

    if (( count == 0 )); then
        show_pal_error "No colors found in $pal_file"
        return 1
    fi

    # Determine columns
    if (( columns > 0 && columns <= 36 )); then
        PAL_ARRAY_X=$columns
    else
        local w
        w=$(awk "BEGIN { w=sqrt($count/2); print (w==int(w)? w : int(w)+1) }" 2>/dev/null || echo 1)
        (( w < 1 )) && w=1
        (( w > 36 )) && w=36
        PAL_ARRAY_X=$w
    fi
    PAL_ARRAY_Y=$(( (count + PAL_ARRAY_X - 1) / PAL_ARRAY_X ))

    # ---------- PASS 2: read actual colors (simple tokenizer) ----------
    local -a colors=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read -ra fields <<< "$line"
        if (( ${#fields[@]} >= 3 )) && [[ ${fields[0]} =~ ^[0-9]+$ ]] && \
           [[ ${fields[1]} =~ ^[0-9]+$ ]] && [[ ${fields[2]} =~ ^[0-9]+$ ]]; then
            colors+=("${fields[0]};${fields[1]};${fields[2]}")
        fi
    done < "$pal_file"

    if (( ${#colors[@]} != count )); then
        show_pal_error "Color count mismatch in $pal_file"
        return 1
    fi

    PAL_ARRAY=("${colors[@]}")
    PAL_SNAME="$name"

    # Recompute all bounding boxes (brush, palette, draw window, menu)
    recalc_boxes
    return 0
}

function draw_pal() {
    local colstart=${BBOX_PALETTE[0]}
    local rowstart=${BBOX_PALETTE[1]}
    local cols=$PAL_ARRAY_X
    local rows=$PAL_ARRAY_Y

    # Column labels
    set_pos $colstart $((rowstart-1))
    local label
    for ((c=0; c<cols; c++)); do
        if (( c < 26 )); then
            label=$(printf "\\$(printf '%03o' $((c+97)))")
        else
            label=$((c-26))
        fi
        printf "${COL_TXTBOR_BG}${COL_MENU_MED}%s" "$label"
    done

    # Rows
    for ((r=0; r<rows; r++)); do
        # Row label
        if (( r < 26 )); then
            label=$(printf "\\$(printf '%03o' $((r+97)))")
        else
            label=$((r-26))
        fi
        set_pos 3 $((rowstart+r))
        printf "${COL_TXTBOR_BG}${COL_MENU_MED}%s" "$label"

        # Color cells – use foreground color for the block
        set_pos $colstart $((rowstart+r))
        for ((c=0; c<cols; c++)); do
            idx=$(( r * cols + c ))
            (( idx >= ${#PAL_ARRAY[@]} )) && break
            mycolor=${PAL_ARRAY[$idx]}
            printf "${FGP}${mycolor}m█"
        done
        printf "\e[0m"   # reset attributes after each row
    done

    # Palette name (truncated to fit within palette width)
    if [[ -n "$PAL_SNAME" ]]; then
        local name="${PAL_SNAME}"
        # Truncate to fit within palette width, add ellipsis if needed
        if (( ${#name} > cols )); then
            name="${name:0:cols-1}…"
        fi
        local name_x=$(( colstart + (cols - ${#name}) / 2 ))
        set_pos $name_x $((rowstart+rows))
        printf "${COL_TXTBOR_BG}${COL_MENU_DRK}%s\e[0m" "$name"
    fi
}

# ----------------------------------------------------------------------
# Compute menu hitboxes from MENU_STRING and current palette position
# ----------------------------------------------------------------------
function setup_menu_boxes() {
    local start_x="${1:-${BBOX_MENUITM[0]}}"
    # Clear arrays
    MENU_ITEM_NAMES=()
    MENU_ITEM_START=()
    MENU_ITEM_END=()

    # Use the same menu string as draw_menu (plain text without ANSI)
    local menu="Help ▒▒ Load ▒▒ Save ▒▒ Glyphs ▒▒ Palettes ▒▒ sprites ▒▒ Text ▒▒ Undo ▒▒ Redo ▒▒ Quit"
    local sep=" ▒▒ "
    local sep_len=${#sep}
    local -a parts=()
    local rest="$menu"

    # Split menu string into parts
    while [[ "$rest" == *"$sep"* ]]; do
        local item="${rest%%$sep*}"
        parts+=("$item")
        rest="${rest#*$sep}"
    done
    parts+=("$rest")

    # Compute per‑item ranges starting from start_x
    local current=$start_x
    local i
    for ((i=0; i<${#parts[@]}; i++)); do
        local item_len=${#parts[i]}
        MENU_ITEM_NAMES+=("${parts[i]}")
        MENU_ITEM_START+=($current)
        MENU_ITEM_END+=($(( current + item_len - 1 )))
        current=$(( current + item_len + sep_len ))
    done
}

# central organ to reposition things after glyph or palette change
function recalc_boxes() {
    # Brush box (depends on glyph array dimensions)
    local column_start=$(( TERMCOLS - CHR_ARRAY_X*3 - 2 ))
    local row_start=$(( TERMROWS - (2*CHR_ARRAY_Y) + 1 ))
    BBOX_BRUSHES[0]=$column_start
    BBOX_BRUSHES[1]=$(( row_start - 1 ))
    BBOX_BRUSHES[2]=$(( column_start + CHR_ARRAY_X*3 + 1 ))
    BBOX_BRUSHES[3]=$(( row_start + 2*CHR_ARRAY_Y - 2 ))

    # Palette box
    BBOX_PALETTE[0]=5
    BBOX_PALETTE[1]=3
    BBOX_PALETTE[2]=$(( BBOX_PALETTE[0] + PAL_ARRAY_X - 1 ))
    BBOX_PALETTE[3]=$(( BBOX_PALETTE[1] + PAL_ARRAY_Y - 1 ))

    # Draw window (left = palette right + 2, top = 3, right = TERMCOLS-2, bottom = brush top - 4)
    BBOX_DRAWWIN[0]=$(( ${BBOX_PALETTE[2]} + 2 ))
    BBOX_DRAWWIN[1]=3
    BBOX_DRAWWIN[2]=$(( TERMCOLS - 2 ))
    BBOX_DRAWWIN[3]=$(( ${BBOX_BRUSHES[1]} - 4 ))

    # Compute menu offset exactly as original: center 86‑char menu within draw window width
    local menu_width=86
    local drawwin_width=$(( ${TERMCOLS} - 1 - ${BBOX_DRAWWIN[0]} ))
    local menu_offset=$(( (drawwin_width - menu_width) / 2 ))
    local menu_x=$(( BBOX_DRAWWIN[0] + menu_offset ))

    # Set menu bounding box
    BBOX_MENUITM=($menu_x 2 $(( menu_x + menu_width - 1 )) 2)

    # Now compute per‑item hitboxes using the same start X
    setup_menu_boxes "$menu_x"
}


# Draw background and border with random patterns
function draw_bg_border() {
        TERMCOLS=$(tput cols)
        TERMROWS=$(tput lines)
        COLEND=$((TERMCOLS-2))
        ROWEND=$((TERMROWS-1))
        START=1

        local -a BORDERS=(
                "═ ║ ╔ ╗ ╚ ╝"
                "─ │ ┌ ┐ └ ┘"
                "━ ┃ ┏ ┓ ┗ ┛"
                "═ ║ ╔ ╗ ╚ ╝"
        )
        local border_set="${BORDERS[$(( RANDOM % ${#BORDERS[@]} ))]}"
        read -ra border <<< "$border_set"
        local h="${border[0]}" v="${border[1]}" tl="${border[2]}" tr="${border[3]}" bl="${border[4]}" br="${border[5]}"

        declare -a BGPATS=(
            "1◖◗ " "2-◖◗-" "1◄►." "2◖◗  " "2◖◘◗." "1◄►."
            "1╮╰." "2╭╯╰╮"
            "0░▒▓▒░" "2░▒▓█" "0▩"
            "2╱╲." "1╱╲╳" "2◢◣" "1◢◣◤◥" "2▀▄█"
            "2▤▥▦▧▩" "2☰☱☲☳☴☵☶☷" "2⚌⚍"
            "4⣀⣤⣶⣿⣿⣶⣤⣀" "2⣿⣶⣤⣀" "2⡀⡄⡆⡇" "2⣀⣤⣶⣿" "2⢕ ⢕ " "1⢕"
            "2╱╲." "1╱╲j" "2◢◣" "1◢◣◤◥" "2▀▄█" "1░▒▓█"
        )
        random_index=$(( RANDOM % ${#BGPATS[@]} ))
        local patdef="${BGPATS[$random_index]}"
        local shift="${patdef:0:1}"
        MYPAT="${patdef:1}"
        PATWID=${#MYPAT}

        printf "\e[2J"
        set_pos 1 1
        echo -e "${COL_BLACK_BG}${COL_GAMSCR_BR}${tl}$(printf "%0.s${h}" $(seq $START $COLEND))${tr}\e[0m"
        for ((i=2; i<=$ROWEND; ++i)); do
                local offset=$(( (i % 2) * shift ))
                collector="${COL_BLACK_BG}${COL_GAMSCR_BR}${v}${COL_BLACK_BG}${COL_GAMSCR_FG}"
                for ((j=1; j<=$COLEND; j++)); do
                        local index=$(( (j + offset) % PATWID ))
                        collector+="${MYPAT:$index:1}"
                done
                collector+="${COL_BLACK_BG}${COL_GAMSCR_BR}${v}\e[0m\n"
                printf '%b' "$collector"
        done
        echo -ne "${COL_BLACK_BG}${COL_GAMSCR_BR}${bl}$(printf "%0.s${h}" $(seq $START $COLEND))${br}\e[0m"
}

# Draw menu bar
function draw_menu() {
        set_pos $((${BBOX_MENUITM[0]}-1)) 2
        cll=$COL_MENU_LIG; cld=$COL_MENU_DRK; cls=$COL_GAMSCR_FG; clb=$COL_BLACK_BG
        printf "${clb}${cls} ${cll}H${cld}elp${cls} ▒▒ ${cll}L${cld}oad${cls} ▒▒ ${cll}S${cld}ave${cls} ▒▒ ${cll}G${cld}lyphs${cls} ▒▒ ${cll}P${cld}alettes${cls} ▒▒ ${cld}spr${cll}I${cld}tes${cls} ▒▒ ${cll}T${cld}ext${cls} ▒▒ ${cll}U${cld}ndo${cls} ▒▒ ${cll}R${cld}edo${cls} ▒▒ ${cll}Q${cld}uit${cls} ▒"
}

# ----------------------------------------------------------------------
# NEW INPUT STATE MACHINE (replaces old get_input)
# ----------------------------------------------------------------------
STATE=0
ESC_BUF=""
EVENT_READY=""
junk=""

# Parse X10 mouse sequence: ESC [ M Cb Cx Cy
parse_x10_mouse() {
    local seq="$1"
    local b1="${seq:3:1}" b2="${seq:4:1}" b3="${seq:5:1}"
    local raw_btn=$(( $(printf '%d' "'$b1") - 31 ))
    local x=$(( $(printf '%d' "'$b2") - 32 ))
    local y=$(( $(printf '%d' "'$b3") - 32 ))

    MOUSEMOD=0
    (( raw_btn & 4 )) && MOUSEMOD=$((MOUSEMOD | 1))
    (( raw_btn & 8 )) && MOUSEMOD=$((MOUSEMOD | 2))
    (( raw_btn & 16 )) && MOUSEMOD=$((MOUSEMOD | 4))

    local btn=$(( raw_btn & 3 ))
    MOUSEBT="$btn"
    X="$x"; Y="$y"
    USERHIT="Mouse"
    EVENT_READY="yes"
}

parse_sgr_mouse() {
    local seq="$1"
    local data="${seq#*<}"
    local type="${data: -1}"
    local params="${data%?}"
    local -a parts
    IFS=';' read -ra parts <<< "$params"
    local raw_btn="${parts[0]}"
    local x="${parts[1]}"
    local y="${parts[2]}"

    MOUSEMOD=0
    if (( raw_btn >= 16 )); then
        MOUSEMOD=$((MOUSEMOD | 4))
        raw_btn=$(( raw_btn - 16 ))
    fi
    if (( raw_btn >= 8 )); then
        MOUSEMOD=$((MOUSEMOD | 2))
        raw_btn=$(( raw_btn - 8 ))
    fi
    if (( raw_btn >= 4 )); then
        MOUSEMOD=$((MOUSEMOD | 1))
        raw_btn=$(( raw_btn - 4 ))
    fi

    MOUSEBT="$raw_btn"
    X="$x"; Y="$y"
    USERHIT="Mouse"
    EVENT_READY="yes"
}

# Handle CSI sequences (arrows, etc.)
handle_csi_sequence() {
        local seq="$1"
        case "$seq" in
                "$ESC"[A) USERHIT="KeyUp" ;;
                "$ESC"[B) USERHIT="KeyDown" ;;
                "$ESC"[C) USERHIT="KeyRight" ;;
                "$ESC"[D) USERHIT="KeyLeft" ;;
                *)        USERHIT="KeyOther"; KEYCMD="$seq" ;;
        esac
        EVENT_READY="yes"
}

# Feed one byte into the state machine
process_byte() {
        local byte="$1"
        case $STATE in
                0) # IDLE
                        if [[ "$byte" == $'\e' ]]; then
                                STATE=1
                                ESC_BUF="$byte"
                        else
                                KEYCMD="$byte"
                                USERHIT="KeyOther"
                                if [[ "$byte" == "Q" && "$IN_FILE_SELECTOR" -eq 0 ]]; then
                                        at_exit
                                fi
                                EVENT_READY="yes"
                        fi
                        ;;
                1) # ESC received
                        ESC_BUF+="$byte"
                        case "$byte" in
                                '[') STATE=2 ;;
                                *) USERHIT="KeyOther"
                                        KEYCMD="$byte"
                                        EVENT_READY="yes"
                                        STATE=0; ESC_BUF=""
                                        ;;
                        esac
                        ;;
                2) # ESC [
                        ESC_BUF+="$byte"
                        case "$byte" in
                                'M') STATE=3 ;;
                                '<') STATE=4 ;;
                                *)
                                        local code=$(printf '%d' "'$byte")
                                        if (( code >= 64 && code <= 126 )); then
                                                handle_csi_sequence "$ESC_BUF"
                                                STATE=0; ESC_BUF=""
                                        else
                                                STATE=5
                                        fi
                                        ;;
                        esac
                        ;;
                3) # ESC [ M   (X10 mouse)
                        ESC_BUF+="$byte"
                        if (( ${#ESC_BUF} >= 6 )); then
                                parse_x10_mouse "$ESC_BUF"
                                STATE=0; ESC_BUF=""
                        fi
                        ;;
                4) # ESC [ <   (SGR mouse)
                        ESC_BUF+="$byte"
                        if [[ "$byte" == 'M' || "$byte" == 'm' ]]; then
                                parse_sgr_mouse "$ESC_BUF"
                                STATE=0; ESC_BUF=""
                        fi
                        ;;
                5) # CSI sequence with parameters
                        ESC_BUF+="$byte"
                        if [[ "$byte" =~ [@-~] ]]; then
                                handle_csi_sequence "$ESC_BUF"
                                STATE=0; ESC_BUF=""
                        fi
                        ;;
        esac
}

# Helper: list files and directories (excludes dotfiles)
function list_files() {
    local pattern="$1"
    FILE_LIST=()
    FILE_LIST+=("..")   # Always show parent directory
    # List directories (excluding hidden ones)
    while IFS= read -r -d '' dir; do
        FILE_LIST+=("${dir#./}/")
    done < <(find . -maxdepth 1 -type d ! -name . ! -name '.*' -print0 2>/dev/null | sort -z)
    # List files matching the pattern (excluding hidden ones)
    while IFS= read -r -d '' file; do
        FILE_LIST+=("${file#./}")
    done < <(find . -maxdepth 1 -type f -iname "$pattern" ! -name '.*' -print0 2>/dev/null | sort -z)
}

# Truncate a filename for display
function truncate_name() {
        local name="$1"
        local base ext
        if [[ -d "$name" ]]; then
                echo "$name"
                return
        fi
        if [[ "$name" == *.* ]]; then
                base="${name%.*}"
                ext=".${name##*.}"
        else
                base="$name"
                ext=""
        fi
        if (( ${#base} > 17 )); then
                base="${base:0:17}"
                echo "${base}...${ext}"
        else
                echo "$name"
        fi
}

function truncate_path_display() {
        local fullpath="$1"
        local basename="${fullpath##*/}"
        local base ext
        if [[ "$basename" == *.* ]]; then
                base="${basename%.*}"
                ext=".${basename##*.}"
        else
                base="$basename"
                ext=""
        fi
        if (( ${#base} > 17 )); then
                base="${base:0:17}"
                echo "${base}...${ext}"
        else
                echo "$basename"
        fi
}

# Global variable for page offset
declare -g FILE_PAGE_START=0

# Recompute grid dimensions and visible counts based on draw window
function file_grid_dims() {
    local draw_w=$(( BBOX_DRAWWIN[2] - BBOX_DRAWWIN[0] ))
    local draw_h=$(( BBOX_DRAWWIN[3] - BBOX_DRAWWIN[1] ))
    local max_w=0
    local disp
    for name in "${FILE_LIST[@]}"; do
        disp=$(truncate_name "$name")
        (( ${#disp} > max_w )) && max_w=${#disp}
    done
    max_w=$(( max_w + 2 ))
    FILE_NUM_COLS=$(( (draw_w - 2) / max_w ))
    (( FILE_NUM_COLS < 1 )) && FILE_NUM_COLS=1
    FILE_NUM_ROWS=$(( (draw_h - 2) / 1 ))   # each row uses 1 line
    (( FILE_NUM_ROWS < 1 )) && FILE_NUM_ROWS=1
    FILE_VISIBLE=$(( FILE_NUM_COLS * FILE_NUM_ROWS ))
}

# Draw the file selector overlay (bounded to draw window)
function draw_file_selector() {
    local draw_x=${BBOX_DRAWWIN[0]}
    local draw_y=${BBOX_DRAWWIN[1]}
    local draw_w=$(( ${BBOX_DRAWWIN[2]} - ${BBOX_DRAWWIN[0]} ))
    local draw_h=$(( ${BBOX_DRAWWIN[3]} - ${BBOX_DRAWWIN[1]} ))

    # Clear the draw window area
    for ((row=0; row<draw_h; row++)); do
        set_pos $draw_x $((draw_y+row))
        printf "%${draw_w}s" ""
    done

    set_pos $draw_x $draw_y
    printf "${COL_MENU_LIG}Select file (arrows, Enter, Esc)${COL_END}"

    # Compute max display width over ALL files (not just visible)
    local max_w=0
    local -a display_names=()
    local name disp
    for name in "${FILE_LIST[@]}"; do
        disp=$(truncate_name "$name")
        display_names+=("$disp")
        (( ${#disp} > max_w )) && max_w=${#disp}
    done
    max_w=$(( max_w + 2 ))

    local num_entries=${#FILE_LIST[@]}
    FILE_NUM_COLS=$(( (draw_w - 2) / max_w ))
    (( FILE_NUM_COLS < 1 )) && FILE_NUM_COLS=1
    FILE_NUM_ROWS=$(( (draw_h - 2) / 1 ))   # each row uses 1 line
    (( FILE_NUM_ROWS < 1 )) && FILE_NUM_ROWS=1
    FILE_VISIBLE=$(( FILE_NUM_COLS * FILE_NUM_ROWS ))

    # Determine total pages and visible range
    local total_pages=$(( (num_entries + FILE_VISIBLE - 1) / FILE_VISIBLE ))
    local current_page=$(( FILE_PAGE_START / FILE_VISIBLE + 1 ))
    local start_idx=$FILE_PAGE_START
    local end_idx=$(( start_idx + FILE_VISIBLE ))
    (( end_idx > num_entries )) && end_idx=$num_entries

    # Center the grid horizontally within draw window
    local start_x=$(( draw_x + (draw_w - FILE_NUM_COLS * max_w) / 2 ))

    local idx=0
    for ((row=0; row<FILE_NUM_ROWS; row++)); do
        for ((col=0; col<FILE_NUM_COLS; col++)); do
            idx=$(( row * FILE_NUM_COLS + col ))
            (( idx >= FILE_VISIBLE )) && break
            local real_idx=$(( start_idx + idx ))
            (( real_idx >= end_idx )) && break
            local x=$(( start_x + col * max_w ))
            local y=$(( draw_y + 1 + row ))
            set_pos $x $y
            if (( real_idx == FILE_INDEX )); then
                printf "${COL_CLKBOR_BG}${COL_MENU_LIG}%-*s${COL_END}" $((max_w-2)) "${display_names[real_idx]}"
            else
                printf "${COL_CHR_BG}${COL_CHR_FG}%-*s${COL_END}" $((max_w-2)) "${display_names[real_idx]}"
            fi
        done
    done

    # Page indicator
    if (( total_pages > 1 )); then
        set_pos $draw_x $(( draw_y + draw_h - 1 ))
        printf "${COL_MENU_DRK}Page %d/%d${COL_END}" "$current_page" "$total_pages"
    fi
}

function file_selector() {
    local pattern="$1"
    local target_var=""
    case "$pattern" in
        *.ans) target_var="LOAD_DIR" ;;
        *.chr) target_var="GLYPH_DIR" ;;
        *.gpl) target_var="PALETTE_DIR" ;;
        *)     target_var="LOAD_DIR" ;;
    esac

    # Determine starting directory
    local start_dir=""
    local saved_dir=$(fs_state_get "$pattern" "dir")
    if [[ -n "$saved_dir" && -d "$saved_dir" ]]; then
        start_dir="$saved_dir"
    else
        case "$target_var" in
            LOAD_DIR)   start_dir="$LOAD_DIR" ;;
            GLYPH_DIR)  start_dir="$GLYPH_DIR" ;;
            PALETTE_DIR) start_dir="$PALETTE_DIR" ;;
        esac
    fi

    # Save original directory and go to start_dir
    local orig_pwd="$PWD"
    cd "$start_dir" 2>/dev/null || { cd "$orig_pwd"; return 1; }

    # Flush any pending input
    IFS= read -r -t 0 -n 1000 dummy 2>/dev/null || true

    # Restore last state for this pattern (index/page)
    local saved_index=$(fs_state_get "$pattern" "index")
    local saved_page=$(fs_state_get "$pattern" "page")

    FILE_DIR="$PWD"
    list_files "$pattern"

    FILE_INDEX=0
    FILE_PAGE_START=0
    if [[ -n "$saved_index" ]]; then
        (( saved_index < ${#FILE_LIST[@]} )) && FILE_INDEX=$saved_index
    fi
    if [[ -n "$saved_page" ]]; then
        FILE_PAGE_START=$saved_page
    fi

    IN_FILE_SELECTOR=1
    draw_file_selector

    local fs_done=0
    local fs_selected=0

    while (( !fs_done )); do
        if IFS= read -r -n1 -t 0.1 byte; then
            if [[ "$byte" == $'\e' ]]; then
                if IFS= read -r -n1 -t 0.05 next1; then
                    if [[ "$next1" == '[' ]]; then
                        if IFS= read -r -n1 -t 0.05 next2; then
                            case "$next2" in
                                A|B|C|D) # Arrow keys
                                    case "$next2" in
                                        A) # Up
                                            if (( FILE_INDEX >= FILE_NUM_COLS )); then
                                                FILE_INDEX=$(( FILE_INDEX - FILE_NUM_COLS ))
                                                if (( FILE_INDEX < FILE_PAGE_START )); then
                                                    FILE_PAGE_START=$(( FILE_INDEX / FILE_VISIBLE * FILE_VISIBLE ))
                                                fi
                                            fi
                                            ;;
                                        B) # Down
                                            if (( FILE_INDEX + FILE_NUM_COLS < ${#FILE_LIST[@]} )); then
                                                FILE_INDEX=$(( FILE_INDEX + FILE_NUM_COLS ))
                                                if (( FILE_INDEX >= FILE_PAGE_START + FILE_VISIBLE )); then
                                                    FILE_PAGE_START=$(( FILE_INDEX / FILE_VISIBLE * FILE_VISIBLE ))
                                                fi
                                            fi
                                            ;;
                                        C) # Right
                                            if (( FILE_INDEX % FILE_NUM_COLS < FILE_NUM_COLS - 1 && FILE_INDEX < ${#FILE_LIST[@]}-1 )); then
                                                (( FILE_INDEX++ ))
                                                if (( FILE_INDEX >= FILE_PAGE_START + FILE_VISIBLE )); then
                                                    FILE_PAGE_START=$(( FILE_PAGE_START + FILE_NUM_COLS ))
                                                fi
                                            fi
                                            ;;
                                        D) # Left
                                            if (( FILE_INDEX % FILE_NUM_COLS > 0 )); then
                                                (( FILE_INDEX-- ))
                                                if (( FILE_INDEX < FILE_PAGE_START )); then
                                                    FILE_PAGE_START=$(( FILE_PAGE_START - FILE_NUM_COLS ))
                                                fi
                                            fi
                                            ;;
                                    esac
                                    draw_file_selector
                                    ;;
                                M) # X10 mouse (simple click)
                                    local b1 b2 b3
                                    IFS= read -r -n1 -t 0.05 b1
                                    IFS= read -r -n1 -t 0.05 b2
                                    IFS= read -r -n1 -t 0.05 b3
                                    local btn=$(( $(printf '%d' "'$b1") - 31 ))
                                    local mx=$(( $(printf '%d' "'$b2") - 32 ))
                                    local my=$(( $(printf '%d' "'$b3") - 32 ))
                                    # Compute grid geometry exactly like draw_file_selector
                                    local draw_x=${BBOX_DRAWWIN[0]}
                                    local draw_y=${BBOX_DRAWWIN[1]}
                                    local draw_w=$(( ${BBOX_DRAWWIN[2]} - draw_x ))
                                    local max_w=0
                                    local name disp
                                    for name in "${FILE_LIST[@]}"; do
                                        disp=$(truncate_name "$name")
                                        (( ${#disp} > max_w )) && max_w=${#disp}
                                    done
                                    max_w=$(( max_w + 2 ))
                                    FILE_NUM_COLS=$(( (draw_w - 2) / max_w ))
                                    (( FILE_NUM_COLS < 1 )) && FILE_NUM_COLS=1
                                    FILE_NUM_ROWS=$(( (${BBOX_DRAWWIN[3]} - draw_y - 2) / 1 ))
                                    (( FILE_NUM_ROWS < 1 )) && FILE_NUM_ROWS=1
                                    FILE_VISIBLE=$(( FILE_NUM_COLS * FILE_NUM_ROWS ))
                                    local start_x=$(( draw_x + (draw_w - FILE_NUM_COLS * max_w) / 2 ))
                                    if (( mx >= start_x && mx < start_x + FILE_NUM_COLS * max_w )); then
                                        local col=$(( (mx - start_x) / max_w ))
                                        local row=$(( my - (draw_y + 1) ))
                                        if (( row >= 0 && row < FILE_NUM_ROWS && col >= 0 && col < FILE_NUM_COLS )); then
                                            local abs_idx=$(( FILE_PAGE_START + row * FILE_NUM_COLS + col ))
                                            if (( abs_idx < ${#FILE_LIST[@]} )); then
                                                FILE_INDEX=$abs_idx
                                                draw_file_selector
                                            fi
                                        fi
                                    fi
                                    ;;
                            esac
                        fi
                    else
                        # Esc alone cancels
                        fs_done=1
                        fs_selected=0
                        SELECTED_FILE=""
                        continue
                    fi
                else
                    # Esc alone cancels
                    fs_done=1
                    fs_selected=0
                    SELECTED_FILE=""
                    continue
                fi
                continue
            fi

            # Normal key handling (Enter, etc.)
            case "$byte" in
                $'\n'|$'\r'|$'\x00')
                    local selected="${FILE_LIST[$FILE_INDEX]}"
                    if [[ "$selected" == ".." ]]; then
                        cd ..
                        FILE_DIR="$PWD"
                        list_files "$pattern"
                        FILE_INDEX=0
                        FILE_PAGE_START=0
                        draw_file_selector
                    elif [[ -d "$selected" ]]; then
                        cd "$selected"
                        FILE_DIR="$PWD"
                        list_files "$pattern"
                        FILE_INDEX=0
                        FILE_PAGE_START=0
                        draw_file_selector
                    else
                        # Save state before returning
                        fs_state_set "$pattern" "dir" "$PWD"
                        fs_state_set "$pattern" "index" "$FILE_INDEX"
                        fs_state_set "$pattern" "page" "$FILE_PAGE_START"
                        SELECTED_FILE="$PWD/$selected"
                        fs_done=1
                        fs_selected=1
                        continue
                    fi
                    ;;
                Q|q)
                    fs_done=1
                    fs_selected=0
                    SELECTED_FILE=""
                    continue
                    ;;
            esac
        fi
    done

    # Update the target directory variable
    case "$target_var" in
        LOAD_DIR)   LOAD_DIR="$PWD" ;;
        GLYPH_DIR)  GLYPH_DIR="$PWD" ;;
        PALETTE_DIR) PALETTE_DIR="$PWD" ;;
    esac

    # Restore original working directory
    cd "$orig_pwd"

    IN_FILE_SELECTOR=0
    return 0
}

# ----------------------------------------------------------------------
# Status-line filename editor for saving
# ----------------------------------------------------------------------
function save_status_dialog() {
    # Disable mouse reporting to prevent escape-sequence junk from being read as input
    printf "\e[?1002l"     # Turn off mouse tracking (X10/SGR)
#    printf "\e[?1006l"     # TODO: KEEP OR REMOVE? Enable SGR extended coordinates
    # Flush any pending input (e.g., leftover mouse bytes)
    IFS= read -r -t 0 -n 1000 dummy 2>/dev/null || true

    local initial="$1"
    local input="$initial"
    local cursor=${#input}
    local status_row=${BBOX_DRAWWIN[3]}
    local status_left=${BBOX_DRAWWIN[0]}
    local status_width=$(( ${BBOX_DRAWWIN[2]} - ${BBOX_DRAWWIN[0]} + 1 ))
    local prompt="Save as: "
    local prompt_len=${#prompt}
    local char next1 next2

    printf "\e[?25h"
    set_pos $status_left $status_row
    printf "%*s" $status_width ""

    redraw_prompt() {
        set_pos $status_left $status_row
        printf "%s%s" "$prompt" "$input"
        set_pos $((status_left + prompt_len + ${#input})) $status_row
        printf "%*s" $((status_width - prompt_len - ${#input})) ""
        set_pos $((status_left + prompt_len + cursor)) $status_row
    }
    redraw_prompt

    while true; do
        if IFS= read -r -n1 -t 0.1 char; then
            case "$char" in
                $'\x1b')
                    if IFS= read -r -n1 -t 0.05 next1; then
                        if [[ "$next1" == '[' ]]; then
                            if IFS= read -r -n1 -t 0.05 next2; then
                                case "$next2" in
                                    'D') (( cursor > 0 )) && ((cursor--)); redraw_prompt ;;
                                    'C') (( cursor < ${#input} )) && ((cursor++)); redraw_prompt ;;
                                esac
                            fi
                        else
                            :
                        fi
                    else
                        printf "\e[?25l"
                        draw_image
                        # Re-enable mouse tracking before returning
                        printf "\e[?1002h"
                        return 1
                    fi
                    ;;
                $'\x0a'|$'\x0d'|$'\x00')
                    printf "\e[?25l"
                    if [[ -z "$input" ]]; then
                        draw_image
                        # Re-enable mouse tracking before returning
                        printf "\e[?1002h"
                        return 1
                    fi
                    input="${input#"${input%%[![:space:]]*}"}"
                    input="${input%"${input##*[![:space:]]}"}"
                    save_image "$input"
                    set_pos $status_left $status_row
                    printf " Saved as %s" "$input"
                    sleep 1
                    draw_image
                    # Re-enable mouse tracking before returning
                    printf "\e[?1002h"
                    return 0
                    ;;
                $'\x7f'|$'\x08')
                    if (( cursor > 0 )); then
                        input="${input:0:cursor-1}${input:cursor}"
                        ((cursor--))
                        redraw_prompt
                    fi
                    ;;
                $'\x15')
                    input=""
                    cursor=0
                    redraw_prompt
                    ;;
                $'\x03')
                    printf "\e[?25l"
                    draw_image
                    # Re-enable mouse tracking before returning
                    printf "\e[?1002h"
                    return 1
                    ;;
                *)
                    if [[ "$char" =~ [[:print:]] ]]; then
                        input="${input:0:cursor}$char${input:cursor}"
                        ((cursor++))
                        redraw_prompt
                    fi
                    ;;
            esac
        fi
    done
    printf "\e[?1002h"     # enable mouse tracking
#    printf "\e[?1006h"     # TODO: KEEP OR REMOVE? Enable SGR extended coordinates
}

# ----------------------------------------------------------------------
# Mouse click handler
# ----------------------------------------------------------------------
function click_item() {
    if [[ "$X" -ge "${BBOX_PALETTE[0]}" ]] && \
       [[ "$Y" -ge "${BBOX_PALETTE[1]}" ]] && \
       [[ "$X" -le "${BBOX_PALETTE[2]}" ]] && \
       [[ "$Y" -le "${BBOX_PALETTE[3]}" ]] ; then
        local mycol=$((X - ${BBOX_PALETTE[0]}))
        local myrow=$((Y - ${BBOX_PALETTE[1]}))
        local myind=$(( myrow * PAL_ARRAY_X + mycol ))
        local mycolor=${PAL_ARRAY[$myind]}
        case "${MOUSEBT}" in
            1)  MYFG=$mycolor
                show_fgbg;;
            3)  MYBG=$mycolor
                show_fgbg;;
        esac
        return
    fi

    # Brush region
    if [[ "$X" -ge "${BBOX_BRUSHES[0]}" ]] && \
        [[ "$Y" -ge "${BBOX_BRUSHES[1]}" ]] && \
        [[ "$X" -le "${BBOX_BRUSHES[2]}" ]] && \
        [[ "$Y" -le "${BBOX_BRUSHES[3]}" ]] ; then
         local mycol=$(( (X - 1 - ${BBOX_BRUSHES[0]}) / 3 ))
         local myrow=$(( (Y - ${BBOX_BRUSHES[1]}) / 2 ))
         if (( mycol >= 0 && mycol < CHR_ARRAY_X && myrow >= 0 && myrow < CHR_ARRAY_Y )); then
             local mybrush=${CHR_ARRAY["$mycol,$myrow"]}
             case "${MOUSEBT}" in
                 1|3)  BRUSH=$mybrush; draw_chr ;;
             esac
         fi
         return
    fi

    # Menu region
    if [[ "$X" -ge "${BBOX_MENUITM[0]}" ]] && \
       [[ "$Y" -ge "${BBOX_MENUITM[1]}" ]] && \
       [[ "$X" -le "${BBOX_MENUITM[2]}" ]] && \
       [[ "$Y" -le "${BBOX_MENUITM[3]}" ]] ; then
        # Help
        if [[ "$X" -ge "((${BBOX_MENUITM[0]}-2))" ]] && [[ "$X" -le "((${BBOX_MENUITM[0]}+4))" ]]; then
            USERHIT=""; X=1; Y=1; act_help; return
        fi
        # Load
        if [[ "$X" -ge "((${BBOX_MENUITM[0]}+5))" ]] && [[ "$X" -le "((${BBOX_MENUITM[0]}+11))" ]]; then
            USERHIT=""; file_selector; return
        fi
        # Save
        if [[ "$X" -ge "((${BBOX_MENUITM[0]}+12))" ]] && [[ "$X" -le "((${BBOX_MENUITM[0]}+18))" ]]; then
            save_status_dialog "$IMAGE_FILE"; return
        fi
        # Glyphs
        if [[ "$X" -ge "((${BBOX_MENUITM[0]}+23))" ]] && [[ "$X" -le "((${BBOX_MENUITM[0]}+31))" ]]; then
            file_selector "*.chr"
            if [[ -n "$SELECTED_FILE" ]]; then
                CHR_NAME="$(basename "$SELECTED_FILE")"
                if load_chr "$SELECTED_FILE"; then
                    handle_resize
                fi
                SELECTED_FILE=""
            fi
            return
        fi
        # Palettes
        if [[ "$X" -ge "((${BBOX_MENUITM[0]}+33))" ]] && [[ "$X" -le "((${BBOX_MENUITM[0]}+43))" ]]; then
            file_selector "*.gpl"
            if [[ -n "$SELECTED_FILE" ]]; then
                PAL_NAME="$(basename "$SELECTED_FILE")"
                if load_pal "$SELECTED_FILE"; then
                    handle_resize
                fi
                SELECTED_FILE=""
            fi
            return
        fi
        # Sprites
        if [[ "$X" -ge "((${BBOX_MENUITM[0]}+44))" ]] && [[ "$X" -le "((${BBOX_MENUITM[0]}+53))" ]]; then
            set_pos $((${BBOX_MENUITM[0]}+44)) 4;  printf "${COL_MENU_MED}> Sprites <"; read -rn1 -t1 char; set_pos $((${BBOX_MENUITM[0]}+44)) 4;  printf "${COL_MENU_MED}           "; return
        fi
        # Text
        if [[ "$X" -ge "((${BBOX_MENUITM[0]}+54))" ]] && [[ "$X" -le "((${BBOX_MENUITM[0]}+61))" ]]; then
            set_pos $((${BBOX_MENUITM[0]}+55)) 4;  printf "${COL_MENU_MED}> Text <"; read -rn1 -t1 char; set_pos $((${BBOX_MENUITM[0]}+55)) 4;  printf "${COL_MENU_MED}        "; return
        fi
        # Undo
        if [[ "$X" -ge "((${BBOX_MENUITM[0]}+62))" ]] && [[ "$X" -le "((${BBOX_MENUITM[0]}+69))" ]]; then
            undo_edit; return
        fi
        # Redo
        if [[ "$X" -ge "((${BBOX_MENUITM[0]}+70))" ]] && [[ "$X" -le "((${BBOX_MENUITM[0]}+78))" ]]; then
            redo_edit; return
        fi
        # Quit
        if [[ "$X" -ge "((${BBOX_MENUITM[0]}+80))" ]] && [[ "$X" -le "((${BBOX_MENUITM[2]}+1))" ]]; then
            set_pos 0 $TERMROWS; at_exit
        fi
    fi

    # Drawing window region
    if [[ "$X" -ge "${BBOX_DRAWWIN[0]}" ]] && \
       [[ "$Y" -ge "${BBOX_DRAWWIN[1]}" ]] && \
       [[ "$X" -le "${BBOX_DRAWWIN[2]}" ]] && \
       [[ "$Y" -le "${BBOX_DRAWWIN[3]}" ]] ; then
        local pickx=$(( X + DRAWWIN_OFFX - BBOX_DRAWWIN[0] ))
        local picky=$(( Y + DRAWWIN_OFFY - BBOX_DRAWWIN[1] ))

        # Ignore clicks outside the image boundaries
        if (( pickx < 0 || pickx >= IMG_WIDTH || picky < 0 || picky >= IMG_HEIGHT )); then
            return
        fi

        case "${MOUSEBT}" in
            1)  # Left click
                if (( MOUSEMOD & 1 )); then
                    # Shift+Left: copy character and colors
                    BRUSH="${IMG_GLYPHS[$pickx,$picky]}"
                    local bothcol="${IMG_COLORS[$pickx,$picky]}"
                    local oldifs="$IFS"
                    IFS=$'\e' read -ra fields <<< "$bothcol"
                    IFS="$oldifs"
                    local fg_part="${fields[1]#*;2;}"
                    local bg_part="${fields[2]#*;2;}"
                    MYFG="${fg_part%m}"
                    MYBG="${bg_part%m}"
                    draw_chr
                    show_fgbg
                else
                    # Normal left: draw
                    # Capture old values before overwriting
                    local oldg="${IMG_GLYPHS[$pickx,$picky]}"
                    local oldcol="${IMG_COLORS[$pickx,$picky]}"
                    local oldfg="" oldbg=""
                    if [[ -n "$oldcol" ]]; then
                        local oIFS="$IFS"
                        IFS=$'\e' read -ra ofields <<< "$oldcol"
                        IFS="$oIFS"
                        local ofg="${ofields[1]#*;2;}"
                        local obg="${ofields[2]#*;2;}"
                        oldfg="${ofg%m}"
                        oldbg="${obg%m}"
                    fi
                    # Store new values
                    local newg="${BRUSH}"
                    local newfg="${MYFG}"
                    local newbg="${MYBG}"
                    # Apply to image
                    IMG_GLYPHS[$pickx,$picky]=$newg
                    IMG_COLORS[$pickx,$picky]="$ESC[38;2;${MYFG}m$ESC[48;2;${MYBG}m"
                    # Append to history (pass clean triplets)
                    append_edit "$pickx" "$picky" "$oldg" "$oldfg" "$oldbg" "$newg" "$newfg" "$newbg"
                    # Redraw cell
                    set_pos $X $Y
                    printf "${BGP}${MYBG}m${FGP}${MYFG}m%1s" $BRUSH
                    SAVED=""
                fi
                ;;
            2)  # Middle click
                if (( MOUSEMOD & 1 )); then
                    # Shift+Middle: pick background color
                    local bothcol="${IMG_COLORS[$pickx,$picky]}"
                    local oldifs="$IFS"
                    IFS=$'\e' read -ra fields <<< "$bothcol"
                    IFS="$oldifs"
                    local bg_part="${fields[2]#*;2;}"
                    MYBG="${bg_part%m}"
                    show_fgbg
                else
                    # Normal middle: pick foreground color
                    local bothcol="${IMG_COLORS[$pickx,$picky]}"
                    local oldifs="$IFS"
                    IFS=$'\e' read -ra fields <<< "$bothcol"
                    IFS="$oldifs"
                    local fg_part="${fields[1]#*;2;}"
                    MYFG="${fg_part%m}"
                    show_fgbg
                fi
                ;;
            3)  # Right click: does nothing
                ;;
        esac
        return
    fi
}

# Show statistics/status line
function show_statsR() {
        statmsg="$1"
        local output=$(eval printf "$statmsg")
        statlen=$(( ${#output} + 2 ))
        set_pos $((TERMCOLS-statlen)) $((BBOX_DRAWWIN[3])); printf "${COL_END}"
        echo -en "$output"
}

# ----------------------------------------------------------------------
# Centered help display
# ----------------------------------------------------------------------
function draw_help_centered() {
    local help_file="$bd_datadir/$HELP_NAME"
    local -a lines=()
    local line
    local max_w=0
    local num_lines=0

    # Read help file into array, compute display width (strip ANSI codes)
    if [[ ! -f "$help_file" ]]; then
        printf "Help file not found: %s\n" "$help_file"
        return 1
    fi

    while IFS= read -r line; do
        lines+=("$line")
        # Strip ANSI escape sequences (ESC [ ... m) for width calculation
        local stripped=$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g')
        local len=${#stripped}
        (( len > max_w )) && max_w=$len
        (( num_lines++ ))
    done < "$help_file"

    # Determine padding if help fits in terminal
    local top_pad=0
    local left_pad=0
    if (( num_lines <= TERMROWS && max_w <= TERMCOLS )); then
        top_pad=$(( (TERMROWS - num_lines) / 2 ))
        left_pad=$(( (TERMCOLS - max_w) / 2 ))
    fi

    # Clear screen and move cursor to top-left
    printf "\e[2J\e[H"

    # Print top padding lines
    for ((i=0; i<top_pad; i++)); do
        echo
    done

    # Print each line with left padding
    for line in "${lines[@]}"; do
        printf "%*s" "$left_pad" ""
        printf '%s\n' "$line"
    done
}

# ----------------------------------------------------------------------
# Help screen
# ----------------------------------------------------------------------
function act_help() {
    # Disable mouse tracking to avoid escape-sequence junk
    printf "\e[?1002l"
#    printf "\e[?1006l"     # TODO: KEEP OR REMOVE? disab SGR extended coordinates
    # Flush any pending input (e.g., leftover mouse bytes)
    IFS= read -r -t 0 -n 1000 dummy 2>/dev/null || true

    # Show help centered
    draw_help_centered

    # Wait for any single keypress
    read -s -n 1

    # Flush any remaining input (in case of extra keys/mouse events)
    IFS= read -r -t 0 -n 1000 dummy 2>/dev/null || true

    # Re-enter raw mode, re-enable mouse, hide cursor
    stty "$_STTY"           # restore saved terminal settings
    stty -echo -icanon     # raw mode
    printf "\e[?1002h"     # enable mouse tracking
#    printf "\e[?1006h"     # TODO: KEEP OR REMOVE? Enable SGR extended coordinates
    printf "\e[?25l"       # hide cursor

    # Redraw the full editor interface
    draw_bg_border
    draw_chr
    draw_pal
    show_fgbg
    draw_drawwin
    draw_image
    draw_menu
}


# Handle keyboard commands
function handle_keys() {
    case "${KEYCMD}" in
        H) act_help ;;
        L) file_selector "*.ans"
            if [[ -n "$SELECTED_FILE" ]]; then
                IMAGE_FILE="$SELECTED_FILE"
                SELECTED_FILE=""
                DRAWWIN_OFFX=0
                DRAWWIN_OFFY=0
                draw_drawwin
                load_image "$IMAGE_FILE"
                load_history
                show_fgbg
                draw_drawwin
                draw_image
            fi
            ;;
        S) save_status_dialog "$IMAGE_FILE" ;;
        G) file_selector "*.chr"
            if [[ -n "$SELECTED_FILE" ]]; then
                CHR_NAME="$(basename "$SELECTED_FILE")"
                if load_chr "$SELECTED_FILE"; then
                    handle_resize
                fi
                SELECTED_FILE=""
            fi
            ;;
        P) file_selector "*.gpl"
            if [[ -n "$SELECTED_FILE" ]]; then
                PAL_NAME="$(basename "$SELECTED_FILE")"
                if load_pal "$SELECTED_FILE"; then
                    handle_resize
                fi
                SELECTED_FILE=""
            fi
            ;;
        I) set_pos 93 4
            printf "${COL_MENU_MED}> Sprites <"
            read -rn1 -t1 char
            set_pos 93 4
            printf "${COL_MENU_MED}           "
            ;;
        T) set_pos 104 4
            printf "${COL_MENU_MED}> Text <"
            read -rn1 -t1 char
            set_pos 104 4
            printf "${COL_MENU_MED}        "
            ;;
        U) undo_edit ;;
            # Backspace (127) and old backspace (8) ALSO trigger undo
            $'\x7f'|$'\x08') undo_edit ;;
        R) redo_edit ;;
        Q) set_pos 0 $TERMROWS; at_exit ;;
        x) temp=$MYBG; MYBG=$MYFG; MYFG=$temp; show_fgbg ;;
        *) set_pos 29 $((TERMROWS-2)) ;;
    esac
}

# Trapped exit function
function at_exit() {
        printf "\e[?9l"
        printf "\e[?12l\e[?25h"
        printf "$COL_END"
        stty "$_STTY"
        set_pos 1 $TERMROWS
        if [[ "$SAVED" == "" ]]; then
                show_statsR '"       Save Image? y/N: " "$myfile"'
                response=""
                read_char response
                if [[ $response == 'Y' ]] || [[ $response == 'y' ]]; then
                        save_status_dialog "$IMAGE_FILE"
                else
                        show_statsR '"               Not Saved " " "'
                fi
        fi
        set_pos 0 $TERMROWS
        printf "\nThank you for using buatae!\n"
        trap - EXIT
        exit
}

# ----------------------------------------------------------------------
# Resize handling
# ----------------------------------------------------------------------
function handle_resize() {
    sleep 0.1s
    TERMCOLS=$(tput cols)
    TERMROWS=$(tput lines)

    # Recompute all bounding boxes based on new terminal size
    recalc_boxes

    # Redraw everything
    draw_bg_border
    draw_chr
    draw_pal
    show_fgbg
    draw_drawwin
    draw_image
    draw_menu

    RESIZE_NEEDED=0
}

# ----------------------------------------------------------------------
# MAIN PROGRAM
# ----------------------------------------------------------------------
trap at_exit ERR EXIT
trap 'RESIZE_NEEDED=1' SIGWINCH

draw_bg_border
load_chr $CHR_NAME; draw_chr  # These are variable size menus which constrain the drawwin 
load_pal $PAL_NAME; draw_pal  # These are variable size menus which constrain the drawwin 
show_fgbg
draw_drawwin
load_image $IMAGE_FILE
load_history    # Load or create shadow file
draw_image
draw_menu

# Main input loop
while :
do
        if (( RESIZE_NEEDED )); then
                handle_resize
        fi

        if (( STATE != 0 )); then
                timeout=0.5
        else
                timeout=0.05
        fi

        if IFS= read -r -n1 -t $timeout byte; then
                process_byte "$byte"
                if [[ -n "$EVENT_READY" ]]; then
                        EVENT_READY=""
                        case "$USERHIT" in
                                Mouse)
                                        show_statsR '"%8s BTN:%2s X:%3s Y:%3s" "$USERHIT" "$MOUSEBT" "$X" "$Y"'
                                        click_item
                                        USERHIT=""
                                        MOUSEBT=""
                                        ;;
                                KeyOther)
                                        show_statsR '"Key: %1s " "$KEYCMD"'
                                        handle_keys
                                        ;;
                                KeyUp)
                                        show_statsR '"Key: ▲ "'
                                        DRAWHGT=$(( ${BBOX_DRAWWIN[3]} - ${BBOX_DRAWWIN[1]} ))
                                        if (( IMG_HEIGHT > DRAWHGT )); then
                                                (( new_value = DRAWWIN_OFFY - 1 ))
                                                if (( new_value < 2 )); then
                                                        DRAWWIN_OFFY=0
                                                else
                                                        DRAWWIN_OFFY=$new_value
                                                fi
                                        fi
                                        draw_image
                                        ;;
                                KeyDown)
                                        show_statsR '"Key: ▼ "'
                                        DRAWHGT=$(( ${BBOX_DRAWWIN[3]} - ${BBOX_DRAWWIN[1]} ))
                                        if (( IMG_HEIGHT > DRAWHGT )); then
                                                (( new_value = DRAWWIN_OFFY + 1 ))
                                                if (( new_value + DRAWHGT >= IMG_HEIGHT )); then
                                                        DRAWWIN_OFFY=$(( IMG_HEIGHT - DRAWHGT ))
                                                        if (( DRAWWIN_OFFY < 0 )); then DRAWWIN_OFFY=0; fi
                                                else
                                                        DRAWWIN_OFFY=$new_value
                                                fi
                                        fi
                                        draw_image
                                        ;;
                                KeyLeft)
                                        show_statsR '"Key: ◄ "'
                                        DRAWWID=$(( ${BBOX_DRAWWIN[2]} - ${BBOX_DRAWWIN[0]} ))
                                        if (( IMG_WIDTH > DRAWWID )); then
                                                (( new_value = DRAWWIN_OFFX - 2 ))
                                                if (( new_value < 3 )); then
                                                        DRAWWIN_OFFX=0
                                                else
                                                        DRAWWIN_OFFX=$new_value
                                                fi
                                        fi
                                        draw_image
                                        ;;
                                KeyRight)
                                        show_statsR '"Key: ► "'
                                        DRAWWID=$(( ${BBOX_DRAWWIN[2]} - ${BBOX_DRAWWIN[0]} ))
                                        if (( IMG_WIDTH > DRAWWID )); then
                                                (( new_value = DRAWWIN_OFFX + 2 ))
                                                if (( new_value + DRAWWID >= IMG_WIDTH )); then
                                                        DRAWWIN_OFFX=$(( IMG_WIDTH - DRAWWID ))
                                                        if (( DRAWWIN_OFFX < 0 )); then DRAWWIN_OFFX=0; fi
                                                else
                                                        DRAWWIN_OFFX=$new_value
                                                fi
                                        fi
                                        draw_image
                                        ;;
                                *)
                                        ;;
                        esac
                fi
        else
                if (( STATE != 0 )); then
                        STATE=0; ESC_BUF=""
                fi
        fi
done

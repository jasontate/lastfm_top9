#!/usr/bin/env bash
set -euo pipefail

# Ensure we use the system BSD date rather than any alias/function.
unalias date 2>/dev/null || true
unset -f date 2>/dev/null || true
DATE="/bin/date"

# CONFIG
USER=""              						# your Last.fm username
API_KEY=""									# your Last.fm API key here
TILE_SIZE=256                 				# size of each square
COLS=3                       				# collage grid columns
ROWS=3                       				# collage grid rows
OUT_DIR="$HOME/Desktop"    
WORK_DIR="$(mktemp -d -t lastfmweek.XXXXXXXX)"
OUT_IMG="$OUT_DIR/lastfm_weekly_collage.png"

# Dependency checks
need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }
}
need curl; need jq; need awk; need sort; need wc; need date

# Use ImageMagick v7 friendly commands if available
if command -v magick >/dev/null 2>&1; then
  IM=magick
  MONTAGE=(magick montage)
else
  need convert; need montage
  IM=convert
  MONTAGE=(montage)
fi

# Exit if API key isn’t set
if [[ -z "$API_KEY" ]]; then
  echo "Please set your Last.fm API key in the API_KEY variable." >&2
  exit 1
fi

# Compute the most recently finished Saturday→Friday window
dow="$($DATE +%w)"           # Sun=0 … Sat=6
d=$(( (dow + 1) % 7 ))       # distance to previous Saturday
[ "$d" -eq 0 ] && d=7        # if today is Sat, go back a full week

START_LABEL="$($DATE -v-"${d}"d +%Y-%m-%d)"
END_LABEL="$($DATE -v-"${d}"d -v+6d +%Y-%m-%d)"
START_EPOCH="$($DATE -v-"${d}"d -v0H -v0M -v0S +%s)"
END_EPOCH="$($DATE -v-"${d}"d -v+6d -v23H -v59M -v59S +%s)"

echo "Building Top 9 for $START_LABEL → $END_LABEL …"

SCROBBLES_TSV="$WORK_DIR/scrobbles.tsv"
: > "$SCROBBLES_TSV"

# Fetch recent tracks within the window
page=1
limit=200
total_pages=1
while (( page <= total_pages )); do
  resp=$(curl -s --get "https://ws.audioscrobbler.com/2.0/" \
	--data-urlencode "method=user.getRecentTracks" \
	--data-urlencode "user=$USER" \
	--data-urlencode "from=$START_EPOCH" \
	--data-urlencode "to=$END_EPOCH" \
	--data-urlencode "limit=$limit" \
	--data-urlencode "page=$page" \
	--data-urlencode "api_key=$API_KEY" \
	--data-urlencode "format=json")

  total_pages=$(printf '%s' "$resp" | jq -r 'try (.recenttracks["@attr"].totalPages|tonumber) catch 1')

  printf '%s' "$resp" | jq -r '
	.recenttracks.track[]?
	| select(.["@attr"].nowplaying != "true")
	| [
		.artist["#text"],
		.album["#text"],
		.name,
		(
		  ( .image[]? | select(.size=="extralarge") | .["#text"] ) //
		  ( .image[]? | select(.size=="large")      | .["#text"] ) //
		  ( .image[]? | select(.size=="medium")     | .["#text"] ) //
		  ""
		)
	  ] | @tsv' >> "$SCROBBLES_TSV"

  (( page++ ))
done

scrobbles_count=$(wc -l < "$SCROBBLES_TSV" | tr -d ' ')
if (( scrobbles_count == 0 )); then
  echo "No scrobbles found in the range $START_LABEL → $END_LABEL." >&2
  exit 0
fi

# Weekly statistics
unique_artists=$(awk -F'\t' '{print $1}' "$SCROBBLES_TSV" | LC_ALL=C sort -u | wc -l | tr -d ' ')
unique_albums=$(awk -F'\t' '{print $1 " — " $2}' "$SCROBBLES_TSV" | LC_ALL=C sort -u | wc -l | tr -d ' ')
unique_tracks=$(awk -F'\t' '{print $1 " — " $3}' "$SCROBBLES_TSV" | LC_ALL=C sort -u | wc -l | tr -d ' ')

# Top 9 albums by playcount
TOP9_TSV="$WORK_DIR/top9.tsv"
awk -F'\t' '
  {
	key=$1" — "$2; img=$4;
	count[key]++; if (img != "" && !(key in firstimg)) firstimg[key]=img
  }
  END {
	for (k in count) {
	  print count[k] "\t" k "\t" firstimg[k]
	}
  }' "$SCROBBLES_TSV" |
  LC_ALL=C sort -nr -k1,1 | head -9 > "$TOP9_TSV"

# Download covers or generate placeholders
IMG_LIST=()
i=1
while IFS=$'\t' read -r plays key img; do
  artist="${key% — *}"
  album="${key#* — }"
  save="$WORK_DIR/tile_$i.jpg"

  if [[ -n "$img" ]]; then
	if ! curl -fsL "$img" -o "$save"; then
	  img=""
	fi
  fi

  if [[ -z "$img" ]]; then
	"$IM" -size "${TILE_SIZE}x${TILE_SIZE}" \
	  -background white -gravity center \
	  -pointsize 18 \
	  label:"$artist\n$album" "$save"
  fi

  "$IM" "$save" -resize "${TILE_SIZE}x${TILE_SIZE}^" -gravity center -extent "${TILE_SIZE}x${TILE_SIZE}" "$save"
  IMG_LIST+=("$save")
  ((i++))
done < "$TOP9_TSV"

# Pad to 9 tiles if necessary
while (( ${#IMG_LIST[@]} < COLS * ROWS )); do
  pad="$WORK_DIR/blank_${#IMG_LIST[@]}.jpg"
  "$IM" -size "${TILE_SIZE}x${TILE_SIZE}" xc:white "$pad"
  IMG_LIST+=("$pad")
done

# Assemble collage using appropriate montage command
"${MONTAGE[@]}" "${IMG_LIST[@]}" -tile "${COLS}x${ROWS}" \
  -geometry "${TILE_SIZE}x${TILE_SIZE}+0+0" -background none "$OUT_IMG"

echo "Top 9 saved to: $OUT_IMG"
echo "Timeframe: $START_LABEL → $END_LABEL"
stats="The Stats: ${unique_artists} artists, ${unique_albums} albums, ${unique_tracks} tracks (${scrobbles_count} scrobbles)"
echo "$stats"
printf "%s" "$stats" | pbcopy
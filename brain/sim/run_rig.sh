#!/usr/bin/env bash
# Run the Sektor5 show on this Mac against the REAL rig: the decks over Pro DJ Link, the leg
# pyramids and rave tubes over the rig router's Wi-Fi, and the par can on a uDMX. No Pi needed.
# (brain/sim/run.sh is the same app against a synthetic rig.) See docs/sim.md.
#
#   brain/sim/run_rig.sh          start it in the background (logs in brain/sim/logs/)
#   brain/sim/run_rig.sh stop     stop it
#
# The Mac goes on the router by Ethernet (brain/tools/mac_rig_ethernet.sh keeps the internet on
# Wi-Fi), and so do the decks. With no decks found it waits for them; the NO DECKS pill offers the
# simulation, and it switches itself off when real decks turn up.
#
# Needs: Homebrew openjdk@21 (deckdash), numpy, and for the par can pyusb + Homebrew libusb.
# Hosts come from .env (S5_PYRAMID_L_HOST etc.), else the .local names.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
LOGS="$REPO/brain/sim/logs"
PAT="brain/sim/fakerig.py|$HOME/sim/fakerig.py|brain/showbrain/showbrain.py|brain/projector/projector.py 8100|brain/visuals/visuals.py 8110|DeckDash"

if [ "${1:-}" = stop ]; then
  pkill -f "$PAT" && echo "show stopped" || echo "nothing running"
  exit 0
fi

JDK="$(brew --prefix openjdk@21 2>/dev/null || true)"
[ -x "$JDK/bin/java" ] || { echo "needs Java 21: brew install openjdk@21"; exit 1; }
PY=python3
"$PY" -c "import numpy" 2>/dev/null || { [ -x brain/sim/.venv/bin/python3 ] && PY="$REPO/brain/sim/.venv/bin/python3"; }
"$PY" -c "import numpy" 2>/dev/null || { echo "needs numpy (brain/sim/run.sh makes a venv with it)"; exit 1; }
"$PY" -c "import usb" 2>/dev/null || echo "note: no pyusb, so no par can ($PY -m pip install --user pyusb; brew install libusb)"

for port in 8080 8090 8100 8110; do
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $port is in use (another show or sim running?): $0 stop"; exit 1
  fi
done

if [ -f .env ]; then set -a; . ./.env; set +a; fi
mkdir -p "$LOGS"
# The services import s5auth from brain/common and serve its page script through these git-ignored links.
ln -sf ../common/web/s5auth.js brain/showbrain/s5auth.js
ln -sf ../../common/web/s5auth.js brain/projector/web/s5auth.js
ln -sf ../../common/web/s5auth.js brain/visuals/web/s5auth.js
export PYTHONPATH="$REPO/brain/common"
export S5_AUTH_FILE="$REPO/brain/sim/no-auth.json"          # no such file: no admin PIN on the Mac (as run.sh)
export S5_PYRAMID_L_HOST="${S5_PYRAMID_L_HOST:-rave-pyramid-l.local}" S5_PYRAMID_R_HOST="${S5_PYRAMID_R_HOST:-rave-pyramid-r.local}"
export S5_TUBE1_HOST="${S5_TUBE1_HOST:-rave-tube-1.local}" S5_TUBE2_HOST="${S5_TUBE2_HOST:-rave-tube-2.local}"
export S5_BOX_HOST="${S5_RIG_BOX_HOST:-127.0.0.1}"                     # no panel box unless S5_RIG_BOX_HOST says so

# deckdash, built from this checkout when its sources are newer than the build. Its simulation runs
# ~/sim/fakerig.py (where deploy.sh puts it on the Pi): link it to this checkout's.
DD=brain/deckdash
[ -d "$DD/lib" ] || (cd "$DD" && ./fetch_libs.sh >/dev/null)
if [ ! -f "$DD/classes/DeckDash.class" ] || [ -n "$(find "$DD" -maxdepth 1 -name '*.java' -newer "$DD/classes/DeckDash.class")" ]; then
  echo "building deckdash..."; mkdir -p "$DD/classes"
  "$JDK/bin/javac" -nowarn -d "$DD/classes" -cp "$DD/lib/*" "$DD"/*.java 2>&1 | grep -v "^Note:" || true
fi
[ -e "$HOME/sim" ] || ln -s "$REPO/brain/sim" "$HOME/sim"
WEB="$LOGS/deckdash-web"                                                # deckdash's pages plus the shared ones
mkdir -p "$WEB"
for f in "$DD"/web/* brain/common/web/*; do ln -sfn "$REPO/$f" "$WEB/$(basename "$f")"; done
(cd "$DD" && nohup "$JDK/bin/java" -Djava.awt.headless=true -Xmx768m -Dweb="$WEB" -Dpreview="$WEB" \
  -DauthFile="$S5_AUTH_FILE" -Dorg.slf4j.simpleLogger.defaultLogLevel=warn \
  -Dorg.slf4j.simpleLogger.log.org.deepsymmetry.beatlink.data.MetadataFinder=off \
  -cp "lib/*:classes" DeckDash > "$LOGS/deckdash.log" 2>&1 &)
sleep 1
nohup "$PY" -u brain/showbrain/showbrain.py     > "$LOGS/showbrain.log" 2>&1 &
nohup "$PY" -u brain/projector/projector.py 8100 > "$LOGS/projector.log" 2>&1 &
nohup "$PY" -u brain/visuals/visuals.py 8110     > "$LOGS/visuals.log"   2>&1 &
sleep 3
if pgrep -f "brain/showbrain/showbrain.py" >/dev/null; then
  echo "Sektor5 running on the real rig (logs in $LOGS). Stop: $0 stop"
  echo "  Focus      http://localhost:8110/show.html"
  echo "  Decks      http://localhost:8080   (click the logo for the System view)"
  echo "  Lighting   http://localhost:8090"
  echo "  Projection http://localhost:8100/edit"
  echo "  Stage      http://localhost:8100/stage.html"
else
  echo "showbrain didn't start:"; tail -n 20 "$LOGS/showbrain.log"; exit 1
fi
